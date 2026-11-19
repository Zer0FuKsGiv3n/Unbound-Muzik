// Unbound Muzik — local affinity scoring (item 7, smart queue refill).
//
// One shared scorer, used by the audio handler (refill ranking) and by
// recommendations.dart (own-mix / Quick Picks), so every surface agrees
// on what "liked" means. Pure local computation over in-memory stats —
// zero network calls.
//
// Design (from the deep dive): bounded 0–1 per-track affinity. All terms
// are normalized so no single signal can dominate, and every term is
// small-sample-shrunk so 1 play ≠ 100 plays. Affinity only RE-RANKS
// tracks YouTube already proposed, within artist buckets — it never
// generates candidates and never re-weights bucket sizes, so it cannot
// collapse the queue to the same few songs.

import 'dart:math' as math;

import '../models/track_stats.dart';

/// Affinity of a track, 0.0–1.0. [stats] is null for a never-played
/// track, which gets the neutral prior 0.50 — discoverable, not buried.
/// [liked] is the track's liked state (denormalized in TrackStats, but
/// passed explicitly so callers with only a liked list can use it).
///
/// Formula: clamp(0.40*completionRate + 0.20*playTerm + 0.20*likeTerm
/// + 0.20*recency − 0.25*skipRate, 0, 1), where completionRate is
/// Laplace-smoothed (completions+1)/(starts+2), playTerm is
/// log-damped, recency has a 30-day half-life, and skipRate is the
/// early-skip fraction. These are starting values to tune by feel —
/// a principled synthesis from open-source patterns, not a copied
/// proven formula.
double trackAffinity(TrackStats? stats, {required bool liked}) {
  if (stats == null) return 0.50;
  final starts = stats.playCount;
  final completionRate = (stats.completions + 1) / (starts + 2);
  final playTerm = logPlayTerm(starts);
  final likeTerm = liked || stats.liked ? 1.0 : 0.0;
  final daysSince = stats.lastPlayedAtMs <= 0
      ? 365.0
      : DateTime.now()
              .difference(
                DateTime.fromMillisecondsSinceEpoch(stats.lastPlayedAtMs),
              )
              .inDays
              .toDouble();
  final recency = math.pow(0.5, daysSince / 30).toDouble();
  final skipRate = starts <= 0 ? 0.0 : stats.earlySkips / starts;
  final score = 0.40 * completionRate +
      0.20 * playTerm +
      0.20 * likeTerm +
      0.20 * recency -
      0.25 * skipRate;
  return score.clamp(0.0, 1.0);
}

/// Mean affinity of an artist's top 3 scored tracks, for ranking artist
/// buckets against each other. Artists with fewer than 2 scored tracks
/// fall back to 0.50 (a single track is not evidence about an artist).
double artistAffinity(Iterable<TrackStats> artistStats) {
  final scored = artistStats.where((s) => s.playCount > 0).toList();
  if (scored.length < 2) return 0.50;
  scored.sort((a, b) =>
      trackAffinity(b, liked: b.liked)
          .compareTo(trackAffinity(a, liked: a.liked)));
  final top = scored.take(3).toList();
  var sum = 0.0;
  for (final s in top) {
    sum += trackAffinity(s, liked: s.liked);
  }
  return sum / top.length;
}
