// Unbound Muzik — shared data model.
// One model for both bodies (web app and APK), so a like on the web is a
// like in the APK. No account is ever required to hold the data together.
// Export/import first; real sync only if it proves necessary.
// Mirrors the web app's src/types.ts exactly.

/// A single song. `id` is the YouTube video ID (11 characters) for
/// YouTube tracks, or a local file id for downloaded/local tracks.
class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    this.thumb = '',
    this.duration,
    this.source = TrackSource.youtube,
  });

  final String id;
  final String title;
  final String artist;

  /// Thumbnail URL. May be empty — the UI draws a gradient cover then.
  final String thumb;

  /// Duration in seconds, when known.
  final int? duration;

  final TrackSource source;

  factory Track.fromJson(Map<String, dynamic> json) {
    return Track(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String? ?? 'Unknown artist',
      thumb: json['thumb'] as String? ?? '',
      duration: json['duration'] as int?,
      source: json['source'] == 'local'
          ? TrackSource.local
          : TrackSource.youtube,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'thumb': thumb,
        'duration': duration,
        'source': source.name,
      };
}

enum TrackSource { youtube, local }

class Playlist {
  const Playlist({
    required this.id,
    required this.title,
    required this.trackIds,
    required this.createdAt,
  });

  final String id;
  final String title;
  final List<String> trackIds;
  final int createdAt;

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'] as String,
      title: json['title'] as String,
      trackIds: (json['trackIds'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      createdAt: json['createdAt'] as int,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'trackIds': trackIds,
        'createdAt': createdAt,
      };
}

enum TabKey { home, search, library, queue, radio }

/// What a search can honestly report. Never a silent empty list.
sealed class SearchState {
  const SearchState();
}

class SearchIdle extends SearchState {
  const SearchIdle();
}

class SearchLoading extends SearchState {
  const SearchLoading();
}

class SearchReady extends SearchState {
  const SearchReady(this.tracks);
  final List<Track> tracks;
}

class SearchEmpty extends SearchState {
  const SearchEmpty(this.query);
  final String query;
}

class SearchError extends SearchState {
  const SearchError(this.message);
  final String message;
}

String formatDuration(int? seconds) {
  if (seconds == null) return '';
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
