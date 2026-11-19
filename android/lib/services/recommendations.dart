// Unbound Muzik — recommendations.
// Two modes, exactly like the Musify "magic if" that Daniel asked for:
//   - Own mix (default): liked + recently played + a sample of playlists,
//     shuffled, no network. Instant, always works.
//   - External (opt-in): expand the 5 most recent seeds through related
//     videos, scored by position x recency, top 15. Borrowed
//     intelligence, only when asked for.
// Search is never touched by this switch. Tapping a recommendation only
// changes the queue when Daniel taps it.
// Mirrors the web app's recommendations.ts — the external path here uses
// the APK's real related-videos data instead of the web's search
// simulation.

import '../models/track.dart';
import '../models/track_stats.dart';
import 'affinity.dart';
import 'youtube_service.dart';

List<Track> getOwnRecommendations(
  List<Track> liked,
  List<Track> recentlyPlayed,
  List<Track> playlistTracks, {
  int count = 15,
  Map<String, TrackStats>? stats,
  bool Function(Track track)? isLiked,
}) {
  final seen = <String>{};
  final pool = <Track>[];
  for (final track in [...liked, ...recentlyPlayed, ...playlistTracks]) {
    if (seen.contains(track.id)) continue;
    seen.add(track.id);
    pool.add(track);
  }
  pool.shuffle();
  // When listening stats are available, rank by the same affinity
  // scorer the refill uses, so every surface agrees on what "liked"
  // means. Equal-affinity tracks stay in shuffled order (variety).
  if (stats != null) {
    pool.sort((a, b) {
      final aAff = trackAffinity(
        stats[a.id],
        liked: isLiked?.call(a) ?? false,
      );
      final bAff = trackAffinity(
        stats[b.id],
        liked: isLiked?.call(b) ?? false,
      );
      return bAff.compareTo(aAff);
    });
  }
  return pool.take(count).toList();
}

Future<List<Track>> getExternalRecommendations(
  YoutubeService yt,
  List<Track> recentlyPlayed, {
  int count = 15,
}) async {
  final seeds = recentlyPlayed.take(5).toList();
  if (seeds.isEmpty) return [];
  final scored = <String, ({Track track, int score})>{};
  for (var seedIndex = 0; seedIndex < seeds.length; seedIndex++) {
    final seed = seeds[seedIndex];
    final recencyWeight = seeds.length - seedIndex;
    final batch = await yt.fetchRelatedTracks(seed);
    for (var position = 0; position < batch.length && position < 8; position++) {
      final track = batch[position];
      final positionWeight = 8 - position;
      final score = positionWeight * recencyWeight;
      final existing = scored[track.id];
      if (existing == null || score > existing.score) {
        scored[track.id] = (track: track, score: score);
      }
    }
  }
  final sorted = scored.values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  return sorted.take(count).map((e) => e.track).toList();
}

Future<List<Track>> getRecommendedTracks(
  YoutubeService yt, {
  required bool external,
  required List<Track> liked,
  required List<Track> recentlyPlayed,
  required List<Track> playlistTracks,
  Map<String, TrackStats>? stats,
  bool Function(Track track)? isLiked,
}) async {
  final own = getOwnRecommendations(
    liked,
    recentlyPlayed,
    playlistTracks,
    stats: stats,
    isLiked: isLiked,
  );
  if (!external) return own;
  final ext = await getExternalRecommendations(yt, recentlyPlayed);
  return ext.isNotEmpty ? ext : own;
}
