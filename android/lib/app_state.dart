// Unbound Muzik — the app's shared state.
//
// One ChangeNotifier holds the library (liked songs, real history,
// playlists, settings) and the current search / recommendation / radio
// results. Playback itself lives in UnboundAudioHandler; this class
// listens to the handler's UI state and re-notifies, so the screens
// redraw when playback changes. Mirrors the web app's App.tsx state,
// minus the player (which is the handler here).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import 'services/audio_handler.dart';
import 'services/downloads_service.dart';
import 'services/recommendations.dart';
import 'services/storage_service.dart';
import 'services/youtube_service.dart';

class AppState extends ChangeNotifier {
  AppState({
    required this.storage,
    required this.youtube,
    required this.downloads,
    required this.handler,
  }) {
    _liked = storage.loadLiked();
    _recentlyPlayed = storage.loadRecentlyPlayed();
    _playlists = storage.loadPlaylists();
    _repeatOn = storage.loadRepeat();
    _externalRecs = storage.loadExternalRecommendations();
    _radioAutoPlay = storage.loadRadioAutoPlay();
    _handlerSub = handler.uiState.listen((state) {
      _playback = state;
      // History only grows on confirmed plays; reload it when it changes.
      _recentlyPlayed = storage.loadRecentlyPlayed();
      notifyListeners();
    });
    _playback = handler.currentUiState;
    unawaited(loadRecommendations());
  }

  final StorageService storage;
  final YoutubeService youtube;
  final DownloadsService downloads;
  final UnboundAudioHandler handler;

  late final StreamSubscription<PlaybackUiState> _handlerSub;

  // --- Library ---

  List<Track> _liked = [];
  List<Track> get liked => _liked;

  List<Track> _recentlyPlayed = [];
  List<Track> get recentlyPlayed => _recentlyPlayed;

  List<Playlist> _playlists = [];
  List<Playlist> get playlists => _playlists;

  Map<String, Track> get trackCache => storage.loadTrackCache();

  // --- Settings ---

  bool _repeatOn = true;
  bool get repeatOn => _repeatOn;

  bool _externalRecs = false;
  bool get externalRecs => _externalRecs;

  bool _radioAutoPlay = false;
  bool get radioAutoPlay => _radioAutoPlay;

  // --- Playback snapshot (from the handler) ---

  late PlaybackUiState _playback;
  PlaybackUiState get playback => _playback;

  // --- Search ---

  SearchState _searchState = const SearchIdle();
  SearchState get searchState => _searchState;

  String _searchQuery = '';
  String get searchQuery => _searchQuery;

  // --- Recommendations ---

  List<Track> _recommendations = [];
  List<Track> get recommendations => _recommendations;

  bool _recsLoading = false;
  bool get recsLoading => _recsLoading;

  // --- Radio ---

  bool _radioLoading = false;
  bool get radioLoading => _radioLoading;

  // --- Notices ---

  String? _notice;
  String? get notice => _notice;

  void dismissNotice() {
    _notice = null;
    notifyListeners();
  }

  // --- Library actions ---

  void toggleLike(Track track) {
    final isLiked = _liked.any((t) => t.id == track.id);
    _liked = isLiked
        ? _liked.where((t) => t.id != track.id).toList()
        : [track, ..._liked];
    storage.saveLiked(_liked);
    storage.registerTracks([track]);
    notifyListeners();
  }

  bool isLiked(Track track) => _liked.any((t) => t.id == track.id);

  void toggleRepeat() {
    _repeatOn = !_repeatOn;
    storage.saveRepeat(_repeatOn);
    handler.setRepeat(_repeatOn);
    notifyListeners();
  }

  void toggleExternalRecs(bool value) {
    _externalRecs = value;
    storage.saveExternalRecommendations(value);
    unawaited(loadRecommendations());
    notifyListeners();
  }

  void toggleRadioAutoPlay(bool value) {
    _radioAutoPlay = value;
    storage.saveRadioAutoPlay(value);
    handler.setRadioAutoPlay(value);
    notifyListeners();
  }

  Future<void> saveQueueAsPlaylist(String name) async {
    final trimmed = name.trim();
    if (_playback.queue.isEmpty) {
      _notice = 'The queue is empty — play something first, then save it.';
      notifyListeners();
      return;
    }
    if (trimmed.isEmpty) {
      _notice = 'Give the playlist a name first.';
      notifyListeners();
      return;
    }
    final playlist = Playlist(
      id: '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-'
          '${DateTime.now().microsecondsSinceEpoch % 100000}',
      title: trimmed,
      trackIds: _playback.queue.map((t) => t.id).toList(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _playlists = [playlist, ..._playlists];
    storage.savePlaylists(_playlists);
    _notice = 'Saved "$trimmed" with ${_playback.queue.length} songs.';
    notifyListeners();
  }

  Future<void> playPlaylist(Playlist playlist) async {
    final cache = trackCache;
    final tracks = playlist.trackIds
        .map((id) => cache[id])
        .whereType<Track>()
        .toList();
    if (tracks.isEmpty) {
      _notice =
          'Those songs are not on this phone yet — play them from Search or Home first, then the playlist will work.';
      notifyListeners();
      return;
    }
    await handler.playAt(0, list: tracks);
  }

  void deletePlaylist(String id) {
    _playlists = _playlists.where((p) => p.id != id).toList();
    storage.savePlaylists(_playlists);
    notifyListeners();
  }

  // --- Search ---

  Future<void> handleSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    _searchQuery = q;
    _searchState = const SearchLoading();
    notifyListeners();
    try {
      final tracks = await youtube.searchTracks(q);
      if (tracks.isEmpty) {
        _searchState = SearchEmpty(q);
      } else {
        storage.registerTracks(tracks);
        _searchState = SearchReady(tracks);
      }
    } catch (e) {
      _searchState = SearchError(_plainSearchError(e));
    }
    notifyListeners();
  }

  String _plainSearchError(Object e) {
    final message = e.toString();
    if (message.contains('403')) {
      return 'Search was refused (403). YouTube may have changed something — try again later.';
    }
    if (message.contains('TimeoutException') ||
        message.contains('timed out')) {
      return 'Search took too long — check your connection and try again.';
    }
    return 'Search failed. Try again in a moment.';
  }

  // --- Recommendations ---

  Future<void> loadRecommendations() async {
    _recsLoading = true;
    notifyListeners();
    try {
      final playlistTracks = _playlists
          .expand((p) => p.trackIds)
          .map((id) => trackCache[id])
          .whereType<Track>()
          .toList();
      final recs = await getRecommendedTracks(
        youtube,
        external: _externalRecs,
        liked: _liked,
        recentlyPlayed: _recentlyPlayed,
        playlistTracks: playlistTracks,
        stats: storage.allListeningStats,
        isLiked: (t) => _liked.any((l) => l.id == t.id),
      );
      storage.registerTracks(recs);
      _recommendations = recs;
    } catch (_) {
      // External recommendations failing must never break Home — fall
      // back to the local mix, which needs no network at all.
      _recommendations =
          getOwnRecommendations(_liked, _recentlyPlayed, []);
    } finally {
      _recsLoading = false;
      notifyListeners();
    }
  }

  // --- Radio ---

  Future<void> startRadio(String artist) async {
    _radioLoading = true;
    notifyListeners();
    try {
      await handler.startRadio(artist);
    } finally {
      _radioLoading = false;
      notifyListeners();
    }
  }

  // --- Downloads ---

  Future<void> downloadTrack(Track track) async {
    try {
      await downloads.downloadTrack(track);
      _notice = 'Downloaded "${track.title}". It is a real file now.';
    } catch (e) {
      _notice = 'Could not download "${track.title}". Try again in a moment.';
    }
    notifyListeners();
  }

  Future<void> deleteDownload(Track track) async {
    await downloads.deleteDownload(track);
    notifyListeners();
  }

  @override
  void dispose() {
    _handlerSub.cancel();
    super.dispose();
  }
}
