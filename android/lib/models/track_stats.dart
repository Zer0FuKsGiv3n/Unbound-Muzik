// Unbound Muzik — per-track listening stats (item 7, smart queue refill).
//
// One record per track ID, stored as a JSON map in SharedPreferences
// (key `listening_stats_v1`). This is local listening history used ONLY
// to re-rank tracks YouTube already proposed — it never generates
// candidates and never leaves the phone. No title/thumb here: stats stay
// small and never duplicate Track.

import 'dart:math' as math;

/// How a track ended, for affinity scoring. Recorded by the audio
/// handler, which is the only place outcomes can be observed.
enum ListenOutcome {
  /// Played to its natural end, or listened to ≥80% of its duration.
  completion,

  /// User pressed next/previous with listened <30s AND ratio <0.25.
  earlySkip,

  /// User pressed next/previous with ratio ≥0.25 (weak signal).
  lateSkip,

  /// App paused/killed mid-track, or any other non-skip end. Adds to
  /// total listened time; counts as a start, neither completion nor skip.
  partial,
}

class TrackStats {
  const TrackStats({
    required this.trackId,
    required this.artist,
    this.playCount = 0,
    this.completions = 0,
    this.earlySkips = 0,
    this.lateSkips = 0,
    this.totalListenSeconds = 0,
    this.lastListenedSeconds = 0,
    this.lastPlayedAtMs = 0,
    this.liked = false,
  });

  final String trackId;
  final String artist;
  final int playCount;
  final int completions;
  final int earlySkips;
  final int lateSkips;
  final int totalListenSeconds;
  final int lastListenedSeconds;
  final int lastPlayedAtMs;
  final bool liked;

  TrackStats copyWith({
    int? playCount,
    int? completions,
    int? earlySkips,
    int? lateSkips,
    int? totalListenSeconds,
    int? lastListenedSeconds,
    int? lastPlayedAtMs,
    bool? liked,
  }) {
    return TrackStats(
      trackId: trackId,
      artist: artist,
      playCount: playCount ?? this.playCount,
      completions: completions ?? this.completions,
      earlySkips: earlySkips ?? this.earlySkips,
      lateSkips: lateSkips ?? this.lateSkips,
      totalListenSeconds: totalListenSeconds ?? this.totalListenSeconds,
      lastListenedSeconds: lastListenedSeconds ?? this.lastListenedSeconds,
      lastPlayedAtMs: lastPlayedAtMs ?? this.lastPlayedAtMs,
      liked: liked ?? this.liked,
    );
  }

  Map<String, dynamic> toJson() => {
        'trackId': trackId,
        'artist': artist,
        'playCount': playCount,
        'completions': completions,
        'earlySkips': earlySkips,
        'lateSkips': lateSkips,
        'totalListenSeconds': totalListenSeconds,
        'lastListenedSeconds': lastListenedSeconds,
        'lastPlayedAtMs': lastPlayedAtMs,
        'liked': liked,
      };

  factory TrackStats.fromJson(Map<String, dynamic> json) {
    return TrackStats(
      trackId: json['trackId'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      playCount: (json['playCount'] as num?)?.toInt() ?? 0,
      completions: (json['completions'] as num?)?.toInt() ?? 0,
      earlySkips: (json['earlySkips'] as num?)?.toInt() ?? 0,
      lateSkips: (json['lateSkips'] as num?)?.toInt() ?? 0,
      totalListenSeconds: (json['totalListenSeconds'] as num?)?.toInt() ?? 0,
      lastListenedSeconds: (json['lastListenedSeconds'] as num?)?.toInt() ?? 0,
      lastPlayedAtMs: (json['lastPlayedAtMs'] as num?)?.toInt() ?? 0,
      liked: json['liked'] as bool? ?? false,
    );
  }
}

/// Classify a track ending into an outcome. [listenedSeconds] is how
/// long the track was actually played; [durationSeconds] is the track
/// length, or null when unknown. Thresholds (from the deep dive):
/// early skip = listened <30s AND ratio <0.25; completion = natural end
/// OR ratio ≥0.80. Tracks shorter than 30s can never be early-skipped.
/// When the duration is unknown, absolute thresholds only (listened
/// ≥240s = completion, <30s = early skip) — never divide by null.
ListenOutcome classifyListenOutcome({
  required bool endedNaturally,
  required int listenedSeconds,
  int? durationSeconds,
}) {
  if (endedNaturally) return ListenOutcome.completion;
  final duration = durationSeconds;
  if (duration == null || duration <= 0) {
    if (listenedSeconds >= 240) return ListenOutcome.completion;
    if (listenedSeconds < 30) return ListenOutcome.earlySkip;
    return ListenOutcome.partial;
  }
  if (duration < 30) {
    // A <30s track played to the end is a completion; a skip of one is
    // a partial, never an early skip (Last.fm rule).
    return listenedSeconds >= duration
        ? ListenOutcome.completion
        : ListenOutcome.partial;
  }
  final ratio = listenedSeconds / duration;
  if (ratio >= 0.80) return ListenOutcome.completion;
  if (listenedSeconds < 30 && ratio < 0.25) {
    return ListenOutcome.earlySkip;
  }
  return ListenOutcome.lateSkip;
}

/// Log-damped play term, capped at 1.0 (10+ plays = max). Exposed for
/// the affinity scorer and for tests.
double logPlayTerm(int playCount) =>
    math.log(1 + playCount) / math.log(1 + 10);
