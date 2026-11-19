// Unbound Muzik — local persistence.
// Everything here is Daniel's own data, on his own phone. No account, no
// server copy, no tracking. SharedPreferences holds small JSON lists only
// (liked songs, recent plays, playlists, track cache, settings).
// Song files belong in app storage, never here.
// Mirrors the web app's storage.ts, plus a persisted track cache so
// playlists keep working across restarts (the web app only keeps tracks
// in-session; the APK can do better).

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';
import '../models/track_stats.dart';

class StorageService {
  static const _likedKey = 'unbound.liked';
  static const _recentKey = 'unbound.recentlyPlayed';
  static const _repeatKey = 'unbound.repeatQueue';
  static const _externalRecKey = 'unbound.externalRecommendations';
  static const _playlistsKey = 'unbound.playlists';
  static const _trackCacheKey = 'unbound.trackCache';
  static const _radioAutoPlayKey = 'unbound.radioAutoPlay';
  static const _listeningStatsKey = 'listening_stats_v1';

  static const maxRecent = 20;
  static const maxTrackCache = 500;

  /// Cap on listening-stats records. Liked tracks are never pruned.
  static const maxListeningStats = 500;

  final SharedPreferences _prefs;

  StorageService(this._prefs) {
    _listeningStats = _loadListeningStats();
    _likedIds = loadLiked().map((t) => t.id).toSet();
  }

  static Future<StorageService> create() async {
    final prefs = await SharedPreferences.getInstance();
    return StorageService(prefs);
  }

  List<T> _readList<T>(
    String key,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final raw = _prefs.getString(key);
    if (raw == null) return <T>[];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return <T>[];
    }
  }

  void _writeList(String key, List<Map<String, dynamic>> items) {
    _prefs.setString(key, jsonEncode(items));
  }

  // --- Liked songs ---

  List<Track> loadLiked() => _readList(_likedKey, Track.fromJson);

  void saveLiked(List<Track> tracks) {
    _likedIds
      ..clear()
      ..addAll(tracks.map((t) => t.id));
    _writeList(_likedKey, tracks.map((t) => t.toJson()).toList());
  }

  // --- Playlists ---

  List<Playlist> loadPlaylists() => _readList(_playlistsKey, Playlist.fromJson);

  void savePlaylists(List<Playlist> playlists) =>
      _writeList(_playlistsKey, playlists.map((p) => p.toJson()).toList());

  // --- Recently Played: a REAL history, newest first. Not the queue.
  // Only grows when a track is actually confirmed playing. Capped at 20.

  List<Track> loadRecentlyPlayed() => _readList(_recentKey, Track.fromJson);

  List<Track> recordPlayed(Track track) {
    final recent =
        loadRecentlyPlayed().where((t) => t.id != track.id).toList();
    recent.insert(0, track);
    final trimmed = recent.take(maxRecent).toList();
    _writeList(_recentKey, trimmed.map((t) => t.toJson()).toList());
    return trimmed;
  }

  // --- Track cache: every track the app has seen, by id, so playlists
  // (which store ids) can play back after a restart.

  Map<String, Track> loadTrackCache() {
    final raw = _prefs.getString(_trackCacheKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (k, v) => MapEntry(k, Track.fromJson(v as Map<String, dynamic>)),
      );
    } catch (_) {
      return {};
    }
  }

  void registerTracks(Iterable<Track> tracks) {
    final cache = loadTrackCache();
    for (final track in tracks) {
      cache[track.id] = track;
    }
    // Keep the cache bounded: drop the oldest entries beyond the cap.
    // (Insertion order is preserved in a Dart map, so this trims the front.)
    while (cache.length > maxTrackCache) {
      cache.remove(cache.keys.first);
    }
    _prefs.setString(
      _trackCacheKey,
      jsonEncode(cache.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  // --- Listening stats (item 7, smart queue refill): per-track history
  // used ONLY to re-rank tracks YouTube already proposed. One JSON map
  // keyed by track id, loaded once at startup, kept in memory, scored
  // from memory. No queries, no new DB dependency.

  late final Map<String, TrackStats> _listeningStats;
  late final Set<String> _likedIds;

  Map<String, TrackStats> _loadListeningStats() {
    final raw = _prefs.getString(_listeningStatsKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (k, v) => MapEntry(k, TrackStats.fromJson(v as Map<String, dynamic>)),
      );
    } catch (_) {
      return {};
    }
  }

  void _persistListeningStats() {
    // Fire-and-forget: a write per song is trivial at this scale
    // (<500 records, ~50–100 KB JSON), and playback never awaits it.
    unawaited(_prefs.setString(
      _listeningStatsKey,
      jsonEncode(_listeningStats.map((k, v) => MapEntry(k, v.toJson()))),
    ));
  }

  /// Stats for one track, or null if it has never been scored.
  TrackStats? statsFor(String trackId) => _listeningStats[trackId];

  /// All stats, for the affinity scorer.
  Map<String, TrackStats> get allListeningStats =>
      Map.unmodifiable(_listeningStats);

  /// Whether a track is currently liked (in-memory liked set, kept in
  /// sync by saveLiked).
  bool isStatsLiked(String trackId) => _likedIds.contains(trackId);

  /// Record how a track ended. Listens under 5 seconds are noise
  /// (accidental taps) and are not recorded at all. A start counts
  /// toward playCount only when listened ≥5s. Prunes to 500 records,
  /// dropping the oldest lastPlayedAtMs among unliked tracks (liked
  /// tracks are never pruned).
  void recordListenOutcome({
    required Track track,
    required ListenOutcome outcome,
    required int listenedSeconds,
    int? durationSeconds,
  }) {
    if (listenedSeconds < 5) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final existing = _listeningStats[track.id];
    final updated = (existing ??
            TrackStats(trackId: track.id, artist: track.artist))
        .copyWith(
      playCount: (existing?.playCount ?? 0) + 1,
      completions: (existing?.completions ?? 0) +
          (outcome == ListenOutcome.completion ? 1 : 0),
      earlySkips: (existing?.earlySkips ?? 0) +
          (outcome == ListenOutcome.earlySkip ? 1 : 0),
      lateSkips: (existing?.lateSkips ?? 0) +
          (outcome == ListenOutcome.lateSkip ? 1 : 0),
      totalListenSeconds:
          (existing?.totalListenSeconds ?? 0) + listenedSeconds,
      lastListenedSeconds: listenedSeconds,
      lastPlayedAtMs: nowMs,
      liked: _likedIds.contains(track.id),
    );
    _listeningStats[track.id] = updated;
    // Prune past the cap: drop the oldest unliked record.
    while (_listeningStats.length > maxListeningStats) {
      String? oldestId;
      var oldestMs = nowMs;
      for (final entry in _listeningStats.entries) {
        if (entry.value.liked) continue;
        if (entry.value.lastPlayedAtMs < oldestMs) {
          oldestMs = entry.value.lastPlayedAtMs;
          oldestId = entry.key;
        }
      }
      if (oldestId == null) break;
      _listeningStats.remove(oldestId);
    }
    _persistListeningStats();
  }

  // --- Settings ---

  /// Repeat the queue when it ends. Saved, default On.
  bool loadRepeat() => _prefs.getBool(_repeatKey) ?? true;

  void saveRepeat(bool value) => _prefs.setBool(_repeatKey, value);

  /// "External recommendations" — expand home picks from related videos.
  /// Default off.
  bool loadExternalRecommendations() =>
      _prefs.getBool(_externalRecKey) ?? false;

  void saveExternalRecommendations(bool value) =>
      _prefs.setBool(_externalRecKey, value);

  /// Radio: keep playing after the queue ends by pulling in related songs.
  /// Default off — the web app's radio stops cleanly at the end, and the
  /// APK must not surprise Daniel by playing forever unless he asked for it.
  bool loadRadioAutoPlay() => _prefs.getBool(_radioAutoPlayKey) ?? false;

  void saveRadioAutoPlay(bool value) =>
      _prefs.setBool(_radioAutoPlayKey, value);
}
