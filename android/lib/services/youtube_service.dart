// Unbound Muzik — YouTube access, direct from the app.
//
// A native app is not subject to CORS, so the APK talks to YouTube's
// internal endpoints (Innertube) directly through the public
// youtube_explode_dart library — the same tool Musify uses, used here as
// a tool only. No API key, no quota, no proxy, no server. (The web app
// cannot do this; that is why it has its own official-lane search.)
//
// THE GREY LANE, STATED PLAINLY: this talks to YouTube's undocumented
// internal systems while pretending to be one of YouTube's own apps.
// It can break whenever YouTube changes its hidden systems, and a play
// here is not counted the same way as a play through the official
// player. That trade is Daniel's explicit, eyes-open choice (Decision 7).

import 'dart:async';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/track.dart';

/// Words YouTube tacks onto titles that are not part of the song.
const _noiseWords = [
  'official video',
  'official audio',
  'official lyric video',
  'official music video',
  'lyric video',
  'music video',
  'official visualizer',
  'visualizer',
  'audio',
  'hd',
  '4k',
];

String _cleanTitle(String raw) {
  var title = raw.trim();
  // Strip "(...)" and "[...]" groups that are only noise words.
  title = title.replaceAllMapped(
    RegExp(r'\s*[\(\[]([^\)\]]+)[\)\]]'),
    (match) {
      final inner = match.group(1)!.trim().toLowerCase();
      if (_noiseWords.any((w) => inner == w || inner.startsWith('$w '))) {
        return '';
      }
      return match.group(0)!;
    },
  );
  return title.trim();
}

Track _toTrack(Video video) {
  final duration = video.duration;
  return Track(
    id: video.id.value,
    title: _cleanTitle(video.title),
    // Search results are ordinary YouTube videos, not the YouTube Music
    // catalogue — the artist is guessed from the channel name, exactly
    // the way Musify does it. It is a guess, and the app does not pretend
    // otherwise.
    artist: video.author.trim().isEmpty ? 'Unknown artist' : video.author,
    thumb: video.thumbnails.highResUrl.isNotEmpty
        ? video.thumbnails.highResUrl
        : video.thumbnails.mediumResUrl,
    duration: duration?.inSeconds,
    source: TrackSource.youtube,
  );
}

class YoutubeService {
  YoutubeService() : _yt = YoutubeExplode();

  final YoutubeExplode _yt;

  /// visionOS client, defined here in Unbound's own code from yt-dlp's
  /// public client list — not copied from any app. yt-dlp lists visionOS
  /// among its default clients that work without JavaScript or a PO
  /// token, and unlike androidVr it carries a User-Agent in its payload,
  /// so the player can send the matching headers (see
  /// [streamPlaybackHeaders]). This is the client Musify's vendored
  /// library also defaults to; the definition itself comes from yt-dlp,
  /// the public source both of them draw on.
  static const visionOs = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'VISIONOS',
        'clientVersion': '1.02',
        'deviceMake': 'Apple',
        'deviceModel': 'RealityDevice17,1',
        'userAgent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
        'osName': 'visionOS',
        'osVersion': '26.5.23O471',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// Clients tried in order for stream URLs — the next one is used only
  /// if the previous fails. visionOs goes first: it works without a PO
  /// token and carries a User-Agent, so the player can send the matching
  /// headers. androidVr is next (works without a PO token, but carries
  /// no userAgent, so its URLs get no headers and ExoPlayer uses its
  /// default User-Agent — if googlevideo ties those URLs to a
  /// User-Agent, that shows up as a 403 and the fallbacks are tried).
  /// androidSdkless, ios and android are the remaining fallbacks.
  static final _streamClients = [
    visionOs,
    YoutubeApiClient.androidVr,
    YoutubeApiClient.androidSdkless,
    YoutubeApiClient.ios,
    YoutubeApiClient.android,
  ];

  /// Which client produced each video's stream URL, so playback can send
  /// the matching headers. YouTube's CDN ties a stream URL to the client
  /// that minted it (above all its User-Agent); fetching it later with a
  /// different User-Agent reliably returns HTTP 403, even though the URL
  /// itself is valid. That mismatch — not an invalid URL — is why the app
  /// played nothing: ExoPlayer was sending its own User-Agent.
  final Map<String, YoutubeApiClient> _songClients = {};

  /// Headers googlevideo.com expects for URLs minted by the client that
  /// served [videoId]; a mismatched User-Agent can cause HTTP 403.
  Map<String, String> streamPlaybackHeaders(String videoId) {
    final client = _songClients[videoId] ?? _streamClients.first;
    final userAgent = client.payload['context']?['client']?['userAgent'];
    return {
      if (userAgent is String) 'user-agent': userAgent,
      for (final entry in client.headers.entries)
        entry.key: '${entry.value}',
    };
  }

  /// Forget which client minted [videoId]'s URL, so the next fetch mints
  /// a fresh one. Used by the same-song retry after a load failure: a
  /// dead or stale URL is recoverable by re-minting it.
  void invalidateStreamFor(String videoId) {
    _songClients.remove(videoId);
  }

  void dispose() => _yt.close();

  /// One-box search. Throws on failure — callers must show the error in
  /// plain words. Never returns a silent empty list on failure.
  Future<List<Track>> searchTracks(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final results = await _yt.search
        .search(q)
        .timeout(const Duration(seconds: 15));
    return results.take(20).map(_toTrack).toList();
  }

  /// Artist radio from search (three searches, de-duplicated, shuffled,
  /// stop at 20) — the same shape as the web app's simulation. The APK
  /// also has real related-videos radio; this is the fallback when
  /// related videos are unavailable.
  Future<List<Track>> fetchArtistRadioTracks(String artist) async {
    final seed = artist.trim();
    if (seed.isEmpty) return [];
    final queries = ['$seed music', '$seed songs', '$seed official video'];
    final seen = <String>{};
    final out = <Track>[];
    for (final q in queries) {
      if (out.length >= 20) break;
      late final List<Track> results;
      try {
        results = await searchTracks(q);
      } catch (_) {
        continue;
      }
      for (final track in results) {
        if (seen.contains(track.id)) continue;
        seen.add(track.id);
        out.add(track);
        if (out.length >= 20) break;
      }
    }
    out.shuffle();
    return out;
  }

  /// Real related-videos radio: YouTube's own "what's next" graph for a
  /// video. Returns an empty list when YouTube gives nothing back.
  Future<List<Track>> fetchRelatedTracks(Track track) async {
    try {
      final video = await _yt.videos
          .get(track.id)
          .timeout(const Duration(seconds: 15));
      final related = await _yt.videos
          .getRelatedVideos(video)
          .timeout(const Duration(seconds: 15));
      if (related == null) return [];
      return related.map(_toTrack).toList();
    } catch (_) {
      return [];
    }
  }

  /// The direct audio-file address for a video: highest-bitrate
  /// audio-only stream from the manifest — plus the headers the client
  /// that minted the URL expects (see [_songClients]). Throws on failure.
  Future<({Uri url, Map<String, String> headers})> getAudioStreamUri(
    String videoId,
  ) async {
    final info = await _getBestAudioStream(videoId);
    return (url: info.url, headers: streamPlaybackHeaders(videoId));
  }

  /// Same as [getAudioStreamUri], plus the container name (mp4, webm…)
  /// so downloads can be saved with the right extension. The headers
  /// matter here too: the download fetches the URL itself, so it must
  /// send the minting client's User-Agent or googlevideo.com 403s.
  Future<({Uri url, String container, Map<String, String> headers})>
  getAudioStream(String videoId) async {
    final info = await _getBestAudioStream(videoId);
    return (
      url: info.url,
      container: info.container.name,
      headers: streamPlaybackHeaders(videoId),
    );
  }

  Future<AudioOnlyStreamInfo> _getBestAudioStream(String videoId) async {
    Object? lastError;
    for (final client in _streamClients) {
      try {
        final manifest = await _yt.videos.streams
            .getManifest(videoId, ytClients: [client])
            .timeout(const Duration(seconds: 20));
        final audioOnly = manifest.audioOnly;
        if (audioOnly.isEmpty) {
          throw Exception('No audio stream found for this video.');
        }
        _songClients[videoId] = client;
        return _selectAudioStream(audioOnly.toList());
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? Exception('No audio stream found for this video.');
  }

  /// Pick the audio stream to hand the player. Never hand it a format
  /// it cannot decode: Dolby codecs (ec-3, ac-3, eac3) are dropped
  /// outright. Of the rest, AAC (mp4a) in mp4 is preferred, then
  /// opus/vorbis, then the highest bitrate of what is left. Taking the
  /// raw highest bitrate can pick a Dolby stream that ExoPlayer stalls
  /// on forever.
  AudioOnlyStreamInfo _selectAudioStream(List<AudioOnlyStreamInfo> streams) {
    bool isDolby(AudioOnlyStreamInfo s) {
      final codec = s.audioCodec.toLowerCase();
      return codec.contains('ec-3') ||
          codec.contains('ac-3') ||
          codec.contains('eac3');
    }

    final compatible = streams.where((s) => !isDolby(s)).toList();
    final pool = compatible.isEmpty ? streams : compatible;
    int score(AudioOnlyStreamInfo s) {
      final codec = s.audioCodec.toLowerCase();
      if (codec.contains('mp4a') || codec.contains('aac')) return 3;
      if (codec.contains('opus') || codec.contains('vorbis')) return 2;
      return 1;
    }

    pool.sort((a, b) {
      final scoreDiff = score(b).compareTo(score(a));
      if (scoreDiff != 0) return scoreDiff;
      return b.bitrate.compareTo(a.bitrate);
    });
    return pool.first;
  }
}
