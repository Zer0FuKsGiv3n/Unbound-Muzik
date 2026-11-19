// Unbound Muzik — the audio handler.
//
// This is the APK's playback brain, and it follows the web app's rules
// exactly:
//   - Playback truth: `wantsPlaying` (what Daniel asked for) drives the
//     play/pause commands. `isPlaying` (what just_audio confirmed —
//     true ONLY while the player is actually playing) only labels the
//     button. `isStarting` is derived: wantsPlaying && !isPlaying. The
//     button shows "Starting…" until the player confirms Playing;
//     tapping while Starting cancels the start.
//   - Queue end: Repeat On loops. Repeat Off ends in ONE clean, visible
//     finished state. No end-of-queue step ever depends on a network
//     fetch. Unplayable tracks are skipped; if every track fails in a
//     row, playback stops cleanly with a plain message.
//   - Radio: when the current track is within 5 of the end of a radio
//     queue, more songs are fetched in the background (YouTube's real
//     related-videos data). A track ending while a refill is in flight
//     waits for the refill instead of ending.
//   - History: a track counts as played only when playback is confirmed.
//
// The handler runs inside audio_service's foreground service, so music
// survives the screen turning off, the app being swiped away, and the
// lock screen. The notification / lock-screen / headphone / car buttons
// call play(), pause(), skipToNext() and skipToPrevious() here.

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../models/track.dart';
import '../models/track_stats.dart';
import 'affinity.dart';
import 'downloads_service.dart';
import 'storage_service.dart';
import 'youtube_service.dart';

/// Everything the UI needs to draw, in one snapshot.
class PlaybackUiState {
  const PlaybackUiState({
    required this.queue,
    required this.currentIndex,
    required this.wantsPlaying,
    required this.isPlaying,
    required this.queueEnded,
    required this.repeatOn,
    required this.radioSeed,
    required this.errorMessage,
    required this.radioAutoPlay,
  });

  final List<Track> queue;
  final int currentIndex;
  final bool wantsPlaying;
  final bool isPlaying;
  final bool queueEnded;
  final bool repeatOn;
  final String? radioSeed;
  final String? errorMessage;
  final bool radioAutoPlay;

  Track? get currentTrack =>
      currentIndex >= 0 && currentIndex < queue.length
          ? queue[currentIndex]
          : null;

  bool get isStarting => wantsPlaying && !isPlaying;

  String get statusText {
    if (isPlaying) return 'Playing';
    if (isStarting) return 'Starting…';
    if (queueEnded) return 'Finished';
    if (currentTrack != null) return 'Paused';
    return 'Nothing playing';
  }
}

/// Combined position data for the seek bar: current position, buffered
/// position, and total duration. Kept out of PlaybackUiState on purpose —
/// the seek bar subscribes to this stream directly (StreamBuilder), so
/// the ~5 Hz position ticks rebuild only the seek bar, not the whole app.
/// (Routing position through AppState.notifyListeners() would rebuild all
/// five tabs on every tick.)
class PositionData {
  const PositionData(this.position, this.bufferedPosition, this.duration);

  final Duration position;
  final Duration bufferedPosition;
  final Duration duration;
}

class UnboundAudioHandler extends BaseAudioHandler {
  UnboundAudioHandler({
    required YoutubeService youtube,
    required StorageService storage,
    required DownloadsService downloads,
  })  : _yt = youtube,
        _storage = storage,
        _downloads = downloads {
    _repeatOn = _storage.loadRepeat();
    _radioAutoPlay = _storage.loadRadioAutoPlay();
    _player.playerStateStream.listen(_onPlayerState);
    // Explicit resume after an interruption ends (e.g. a phone call).
    // just_audio resumes only when the interruption type is reported as
    // `pause`; an `unknown`-type interruption leaves the player paused
    // even though the user still wants it playing. This closes that gap:
    // on interruption end, resume only if the user still wants playback
    // and the player is not already playing. If just_audio already
    // resumed, the player is playing and this is a no-op, so it cannot
    // double-resume. Becoming-noisy (headphones unplugged) is
    // deliberately NOT resumed here — just_audio pauses there and
    // staying paused is the correct behaviour.
    unawaited(AudioSession.instance.then((session) {
      // Headphones unplugged / Bluetooth disconnected: pause and STAY
      // paused. Must go through pause() (not _player.pause()) so
      // _wantsPlaying is cleared — otherwise the interruption-end
      // listener below would resume through the phone speaker on the
      // next focus regain. just_audio already pauses the player itself
      // on becoming-noisy; this adds the _wantsPlaying = false + _emit()
      // state fix, so the button and notification show Paused.
      session.becomingNoisyEventStream.listen((_) {
        unawaited(pause());
      });
      session.interruptionEventStream.listen((event) {
        if (!event.begin && _wantsPlaying && !_isPlaying) {
          unawaited(play());
        }
      });
    }));
    _emit();
  }

  final YoutubeService _yt;
  final StorageService _storage;
  final DownloadsService _downloads;
  // Explicit load control: start after only 500ms buffered and resume
  // after only 3s rebuffered, so a stall recovers fast instead of
  // waiting on just_audio's longer defaults.
  final AudioPlayer _player = AudioPlayer(
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        maxBufferDuration: Duration(seconds: 60),
        bufferForPlaybackDuration: Duration(milliseconds: 500),
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 3),
      ),
    ),
  );

  List<Track> _queue = [];
  int _currentIndex = -1;
  bool _wantsPlaying = false;
  bool _isPlaying = false;
  bool _queueEnded = false;
  bool _repeatOn = true;
  bool _radioAutoPlay = false;
  String? _radioSeed;
  String? _errorMessage;
  int _consecutiveErrors = 0;
  bool _awaitingRefill = false;
  bool _waitingForRefill = false;
  bool _resolving = false;
  // Local high-res cover files by track id (item 3). Populated when a
  // cover finishes downloading; _emit() reads it synchronously.
  final Map<String, String> _coverPaths = {};

  final _uiStateController = StreamController<PlaybackUiState>.broadcast();

  Stream<PlaybackUiState> get uiState => _uiStateController.stream;

  /// Combined position/buffered/duration stream for the seek bar.
  /// Combines just_audio's three streams with Rx.combineLatest3.
  /// The seek bar subscribes via StreamBuilder so only it rebuilds.
  Stream<PositionData> get positionDataStream =>
      Rx.combineLatest3<Duration, Duration, Duration?, PositionData>(
        _player.positionStream,
        _player.bufferedPositionStream,
        _player.durationStream,
        (position, bufferedPosition, duration) => PositionData(
          position,
          bufferedPosition,
          duration ?? Duration.zero,
        ),
      );

  PlaybackUiState get currentUiState => PlaybackUiState(
        queue: List.unmodifiable(_queue),
        currentIndex: _currentIndex,
        wantsPlaying: _wantsPlaying,
        isPlaying: _isPlaying,
        queueEnded: _queueEnded,
        repeatOn: _repeatOn,
        radioSeed: _radioSeed,
        errorMessage: _errorMessage,
        radioAutoPlay: _radioAutoPlay,
      );

  Track? get _currentTrack =>
      _currentIndex >= 0 && _currentIndex < _queue.length
          ? _queue[_currentIndex]
          : null;

  /// Notification art for a track: the local high-res cover file when one
  /// has been downloaded, else the remote thumbnail (hqdefault), else
  /// null. audio_service has no fallback chain — a single artUri that
  /// 404s leaves the notification art-less — so the fallback is resolved
  /// here in app code before emitting.
  Uri? _artUriFor(Track track) {
    final coverPath = _coverPaths[track.id];
    if (coverPath != null) return Uri.file(coverPath);
    return track.thumb.isEmpty ? null : Uri.parse(track.thumb);
  }

  /// Fetch (or reuse) the high-res cover for the current track. When it
  /// lands, re-emit so the notification picks up the local file. Called
  /// when a track starts, never from _emit() (which runs far too often
  /// to trigger downloads).
  void _fetchCoverForCurrent() {
    final track = _currentTrack;
    if (track == null) return;
    if (_coverPaths.containsKey(track.id)) return;
    unawaited(_downloads.ensureCover(track).then((file) {
      if (file == null) return;
      _coverPaths[track.id] = file.path;
      if (_currentTrack?.id == track.id) _emit();
    }));
  }

  void _emit() {
    if (!_uiStateController.isClosed) {
      _uiStateController.add(currentUiState);
    }
    // Keep audio_service's own state in step: lock-screen / notification
    // buttons and the media session read from here.
    final track = _currentTrack;
    mediaItem.add(
      track == null
          ? null
          : MediaItem(
              id: track.id,
              title: track.title,
              artist: track.artist,
              // Prefer just_audio's actual duration over the nullable
              // metadata duration: the notification seek bar only shows
              // progress when MediaItem.duration is set, and the metadata
              // duration can be null. Falls back to the track metadata.
              duration: _player.duration ??
                  (track.duration == null
                      ? null
                      : Duration(seconds: track.duration!)),
              artUri: _artUriFor(track),
            ),
    );
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          _wantsPlaying ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: _isPlaying
            ? AudioProcessingState.ready
            : _wantsPlaying
                ? AudioProcessingState.buffering
                : AudioProcessingState.idle,
        playing: _isPlaying,
        queueIndex: _currentIndex < 0 ? null : _currentIndex,
        // Notification seek: updatePosition (plus bufferedPosition) is
        // what makes the notification seek bar move and scrubbable.
        // Do NOT push position continuously — the OS projects it forward
        // from updatePosition/updateTime/speed while playing, so setting
        // it here on playback events (seek, track change, pause) is the
        // correct cadence. PlaybackState has no `position` constructor
        // parameter; updatePosition is the field.
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
      ),
    );
    queue.add(
      _queue
          .map(
            (t) => MediaItem(
              id: t.id,
              title: t.title,
              artist: t.artist,
              artUri: _artUriFor(t),
            ),
          )
          .toList(),
    );
  }

  void _onPlayerState(PlayerState state) {
    final wasPlaying = _isPlaying;
    _isPlaying = state.playing;
    if (_isPlaying && !wasPlaying) {
      // Confirmed playing — only now does the track count as played.
      _consecutiveErrors = 0;
      _errorMessage = null;
      final track = _currentTrack;
      if (track != null) {
        _storage.recordPlayed(track);
      }
    }
    if (state.processingState == ProcessingState.completed) {
      _isPlaying = false;
      _emit();
      _handleTrackEnded();
      return;
    }
    if (state.processingState == ProcessingState.idle &&
        _wantsPlaying &&
        !_queueEnded &&
        !_resolving &&
        _currentTrack != null) {
      // The player stopped on its own while we still wanted to play.
      // Treat it as a playback failure, not as a pause.
      _handlePlaybackError('Playback stopped unexpectedly.');
      return;
    }
    _emit();
  }

  // --- Core playback actions (mirror the web app) ---

  Future<void> playAt(
    int index, {
    List<Track>? list,
    bool keepRadioSeed = false,
  }) async {
    final targetList = list ?? _queue;
    if (index < 0 || index >= targetList.length) return;
    if (list != null && !identical(list, _queue)) {
      _queue = List.of(list);
      if (!keepRadioSeed) _radioSeed = null;
    }
    _currentIndex = index;
    _queueEnded = false;
    _errorMessage = null;
    _consecutiveErrors = 0;
    _wantsPlaying = true;
    final track = targetList[index];
    _storage.registerTracks([track]);
    _emit();
    _fetchCoverForCurrent();
    await _loadCurrent();
    _maybeRefill();
  }

  Future<void> _loadCurrent({bool retried = false}) async {
    final track = _currentTrack;
    if (track == null) return;
    _resolving = true;
    try {
      AudioSource source;
      if (track.source == TrackSource.local) {
        final file = await _downloads.fileFor(track);
        if (file == null) {
          throw Exception('That downloaded file is no longer on the phone.');
        }
        source = AudioSource.uri(file.uri);
      } else {
        final downloaded = await _downloads.fileFor(track);
        if (downloaded != null) {
          // A downloaded copy always wins over streaming.
          source = AudioSource.uri(downloaded.uri);
        } else {
          final stream = await _yt.getAudioStreamUri(track.id);
          // The URL is tied to the client that minted it; ExoPlayer must
          // send that client's User-Agent (in `headers`) or googlevideo
          // answers 403 and nothing plays. That was the no-sound bug.
          source = AudioSource.uri(stream.url, headers: stream.headers);
        }
      }
      // A load that never finishes is a failure, not a wait: ExoPlayer
      // retries a bad URL internally and the Future never completes, so
      // without this timeout the UI sits on "Starting…" forever with no
      // error and no recovery. The timeout turns the hang into a
      // catchable error below.
      await _player.setAudioSource(source).timeout(
        const Duration(seconds: 30),
      );
      if (_wantsPlaying) {
        await _player.play();
      }
    } catch (e) {
      // One fresh-URL retry for the same song: a dead or stale URL is
      // recoverable by minting a new one. Only after that fails do we
      // treat the song as unplayable and move on.
      if (!retried && track.source != TrackSource.local) {
        _yt.invalidateStreamFor(track.id);
        await _loadCurrent(retried: true);
        return;
      }
      _handlePlaybackError(_plainError(e));
    } finally {
      _resolving = false;
    }
  }

  void _finishQueue() {
    _wantsPlaying = false;
    _isPlaying = false;
    unawaited(_player.stop());
    _queueEnded = true;
    _emit();
  }

  /// Record how the current track ended (item 7). [endedNaturally] is
  /// true when the track played to its natural end; false for a user
  /// skip (listened seconds come from the player position at that
  /// moment). The handler is the only place outcomes can be observed,
  /// so it must classify each ending here.
  void _recordOutcomeForCurrent({required bool endedNaturally}) {
    final track = _currentTrack;
    if (track == null) return;
    final listenedSeconds = endedNaturally
        ? (track.duration ?? _player.position.inSeconds)
        : _player.position.inSeconds;
    final outcome = classifyListenOutcome(
      endedNaturally: endedNaturally,
      listenedSeconds: listenedSeconds,
      durationSeconds: track.duration,
    );
    _storage.recordListenOutcome(
      track: track,
      outcome: outcome,
      listenedSeconds: listenedSeconds,
      durationSeconds: track.duration,
    );
  }

  /// Record a partial listen for the current track (app paused/killed
  /// mid-track). Adds to total listened time; counts as a start,
  /// neither completion nor skip. Guarded so a stopped/finished queue
  /// does not record a spurious partial.
  void _recordPartialListen() {
    final track = _currentTrack;
    if (track == null) return;
    if (!_wantsPlaying && !_isPlaying) return;
    final listenedSeconds = _player.position.inSeconds;
    if (listenedSeconds < 5) return;
    _storage.recordListenOutcome(
      track: track,
      outcome: ListenOutcome.partial,
      listenedSeconds: listenedSeconds,
      durationSeconds: track.duration,
    );
  }

  /// Re-rank refill candidates by local affinity (item 7). Groups by
  /// artist, ranks WITHIN each group by affinity (never across the
  /// whole pool, so affinity can't break the artist shaping),
  /// interleaves groups round-robin, and reserves every 6th slot for
  /// the highest-ranked unplayed candidate (ε≈0.15 exploration).
  /// Unplayed tracks score 0.50 (neutral prior).
  List<Track> _rankRefillCandidates(List<Track> candidates) {
    if (candidates.isEmpty) return candidates;
    final groups = <String, List<Track>>{};
    final order = <String>[];
    for (final t in candidates) {
      final key = t.artist.trim().toLowerCase();
      if (!groups.containsKey(key)) {
        groups[key] = [];
        order.add(key);
      }
      groups[key]!.add(t);
    }
    for (final group in groups.values) {
      group.sort((a, b) {
        final aAff = trackAffinity(
          _storage.statsFor(a.id),
          liked: _storage.isStatsLiked(a.id),
        );
        final bAff = trackAffinity(
          _storage.statsFor(b.id),
          liked: _storage.isStatsLiked(b.id),
        );
        return bAff.compareTo(aAff);
      });
    }
    final interleaved = <Track>[];
    var round = 0;
    var added = true;
    while (added) {
      added = false;
      for (final key in order) {
        final group = groups[key]!;
        if (round < group.length) {
          interleaved.add(group[round]);
          added = true;
        }
      }
      round++;
    }
    final unplayed = interleaved
        .where((t) =>
            _storage.statsFor(t.id) == null &&
            !_storage.isStatsLiked(t.id))
        .toList();
    if (unplayed.isEmpty) return interleaved;
    final placed = <String>{};
    final out = <Track>[];
    var unplayedIdx = 0;
    var interIdx = 0;
    while (out.length < interleaved.length) {
      final slot = out.length;
      if (slot % 6 == 5 && unplayedIdx < unplayed.length) {
        final candidate = unplayed[unplayedIdx++];
        if (placed.add(candidate.id)) out.add(candidate);
        continue;
      }
      while (interIdx < interleaved.length &&
          placed.contains(interleaved[interIdx].id)) {
        interIdx++;
      }
      if (interIdx >= interleaved.length) break;
      final next = interleaved[interIdx++];
      if (placed.add(next.id)) out.add(next);
    }
    return out;
  }

  void _handleTrackEnded() {
    if (_queue.isEmpty) return;
    // The track that just ended counts as a completion (natural end).
    // Record it BEFORE advancing, while _currentTrack is still the
    // track that ended.
    _recordOutcomeForCurrent(endedNaturally: true);
    if (_currentIndex < _queue.length - 1) {
      unawaited(playAt(_currentIndex + 1));
      return;
    }
    // Last track ended.
    if (_awaitingRefill) {
      _waitingForRefill = true;
      return;
    }
    if (_repeatOn) {
      unawaited(playAt(0));
      return;
    }
    if (_radioAutoPlay && _currentTrack != null) {
      // Endless play (opt-in only): pull one more related song.
      _pullOneMoreRelated();
      return;
    }
    _finishQueue();
  }

  void _handlePlaybackError(String message) {
    if (_queue.isEmpty || _queueEnded) {
      _errorMessage = message;
      _emit();
      return;
    }
    // Rate-limiting is a connection-wide limit, not a bad song: skipping
    // to the next track would just hit the same limit again, 20 times
    // over, and bury the real reason under a generic message. Stop
    // cleanly so the reason stays on screen.
    if (message.startsWith('YouTube is rate-limiting')) {
      _wantsPlaying = false;
      _isPlaying = false;
      unawaited(_player.stop());
      _errorMessage = message;
      _emit();
      return;
    }
    _errorMessage = message;
    _consecutiveErrors += 1;
    if (_consecutiveErrors >= _queue.length) {
      // Every track failed in a row. Stop cleanly with a plain message.
      _wantsPlaying = false;
      _isPlaying = false;
      unawaited(_player.stop());
      _errorMessage =
          'None of the tracks in this queue could be played. Pick another track to try again.';
      _emit();
      return;
    }
    // Skip the unplayable track.
    if (_currentIndex < _queue.length - 1) {
      unawaited(playAt(_currentIndex + 1));
    } else if (_repeatOn) {
      unawaited(playAt(0));
    } else {
      _finishQueue();
    }
  }

  Future<void> _pullOneMoreRelated() async {
    final current = _currentTrack;
    if (current == null) {
      _finishQueue();
      return;
    }
    final known = _queue.map((t) => t.id).toSet();
    final related = await _yt.fetchRelatedTracks(current);
    final fresh = related.where((t) => !known.contains(t.id)).toList();
    if (fresh.isEmpty) {
      if (_repeatOn) {
        unawaited(playAt(0));
      } else {
        _finishQueue();
      }
      return;
    }
    final grown = [..._queue, fresh.first];
    _storage.registerTracks([fresh.first]);
    _queue = grown;
    _emit();
    unawaited(playAt(grown.length - 1));
  }

  // --- Radio refill (mirror the web app's guarded refill) ---

  void _maybeRefill() {
    final seed = _radioSeed;
    if (seed == null) return;
    if (_queue.isEmpty || _currentIndex < 0) return;
    if (_queue.length - 1 - _currentIndex > 5) return;
    if (_awaitingRefill) return;
    _awaitingRefill = true;
    final oldLength = _queue.length;
    final current = _currentTrack;
    Future<List<Track>> refill;
    if (current != null) {
      refill = _yt.fetchRelatedTracks(current).then(
            (related) => related.isNotEmpty
                ? related
                : _yt.fetchArtistRadioTracks(seed),
          );
    } else {
      refill = _yt.fetchArtistRadioTracks(seed);
    }
    refill.then((fresh) {
      final known = _queue.map((t) => t.id).toSet();
      final extra = fresh.where((t) => !known.contains(t.id)).toList();
      if (extra.isNotEmpty) {
        _storage.registerTracks(extra);
        // Rank within artist groups by local affinity (item 7), then
        // interleave; every 6th slot goes to an unplayed candidate.
        final ranked = _rankRefillCandidates(extra);
        final grown = [..._queue, ...ranked];
        _queue = grown;
        _emit();
        if (_waitingForRefill) {
          _waitingForRefill = false;
          unawaited(playAt(oldLength, keepRadioSeed: true));
        }
      } else if (_waitingForRefill) {
        _waitingForRefill = false;
        if (_repeatOn) {
          unawaited(playAt(0));
        } else {
          _finishQueue();
        }
      }
    }).catchError((_) {
      // A failed refill must never break playback. The queue simply ends
      // normally when it runs out.
      if (_waitingForRefill) {
        _waitingForRefill = false;
        if (_repeatOn) {
          unawaited(playAt(0));
        } else {
          _finishQueue();
        }
      }
    }).whenComplete(() {
      _awaitingRefill = false;
    });
  }

  // --- audio_service callbacks: lock-screen, notification, headphones, car ---

  @override
  Future<void> play() async {
    if (_currentTrack == null) {
      if (_queue.isNotEmpty) {
        await playAt(0);
      }
      return;
    }
    _wantsPlaying = true;
    _queueEnded = false;
    _emit();
    try {
      await _player.play();
    } catch (e) {
      _handlePlaybackError(_plainError(e));
    }
  }

  @override
  Future<void> pause() async {
    // Pausing must not kill the foreground service (the handler was
    // started with androidStopForegroundOnPause: false).
    _wantsPlaying = false;
    _emit();
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    // App/service stopping mid-track: record a partial listen so the
    // track is not treated as unplayed next launch.
    _recordPartialListen();
    _wantsPlaying = false;
    _isPlaying = false;
    _queueEnded = false;
    _emit();
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    if (_queue.isEmpty) return;
    if (_queueEnded) {
      await playAt(0);
      return;
    }
    // The track being skipped from: record an early/late skip.
    _recordOutcomeForCurrent(endedNaturally: false);
    if (_currentIndex < _queue.length - 1) {
      await playAt(_currentIndex + 1);
    } else if (_repeatOn) {
      await playAt(0);
    } else {
      _finishQueue();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_queue.isEmpty) return;
    if (_queueEnded) {
      await playAt(_queue.length - 2 < 0 ? 0 : _queue.length - 2);
      return;
    }
    // The track being skipped from: record an early/late skip.
    _recordOutcomeForCurrent(endedNaturally: false);
    if (_currentIndex > 0) {
      await playAt(_currentIndex - 1);
    } else {
      await playAt(0);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    final index = _queue.indexWhere((t) => t.id == mediaItem.id);
    if (index >= 0) {
      await playAt(index);
    }
  }

  // --- UI-only actions ---

  /// The play/pause button. Tapping while "Starting…" shows cancels the start.
  Future<void> togglePlay() async {
    final track = _currentTrack;
    if (track == null) {
      if (_queue.isNotEmpty) {
        await playAt(0);
      }
      return;
    }
    if (_wantsPlaying && !_isPlaying) {
      _wantsPlaying = false;
      _emit();
      await _player.pause();
      return;
    }
    if (_wantsPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> startRadio(String artist) async {
    final seed = artist.trim();
    if (seed.isEmpty) return;
    _errorMessage = null;
    _emit();
    final tracks = await _yt.fetchArtistRadioTracks(seed);
    if (tracks.isEmpty) {
      _errorMessage =
          'Couldn\'t start a radio station for "$seed" — nothing was found. Try again in a moment.';
      _emit();
      return;
    }
    _storage.registerTracks(tracks);
    _radioSeed = seed;
    await playAt(0, list: tracks, keepRadioSeed: true);
  }

  void clearRadioSeed() {
    _radioSeed = null;
    _emit();
  }

  void setRepeat(bool value) {
    _repeatOn = value;
    _emit();
  }

  void setRadioAutoPlay(bool value) {
    _radioAutoPlay = value;
    _emit();
  }

  void dismissError() {
    _errorMessage = null;
    _emit();
  }

  String _plainError(Object e) {
    final message = e.toString();
    if (message.contains('RequestLimitExceeded') ||
        message.contains('rate limiting') ||
        message.contains('rate-limiting') ||
        message.contains('429')) {
      return 'YouTube is rate-limiting this connection right now — it thinks too many requests came from here. Wait a bit and try one song again later; tapping through more songs will not help while the limit is on.';
    }
    if (message.contains('403')) {
      return 'YouTube refused that song (403). It may work again later — this is the known fragility of the direct path.';
    }
    if (message.contains('TimeoutException') ||
        message.contains('timed out')) {
      return 'That took too long — check your connection and try again.';
    }
    return 'That song could not be played. Try another one.';
  }

  @override
  Future<void> onTaskRemoved() async {
    // Swiping the app away must not kill playback: the foreground
    // service keeps going. Record a partial listen for the current
    // track so it is not treated as unplayed next launch.
    _recordPartialListen();
  }
}
