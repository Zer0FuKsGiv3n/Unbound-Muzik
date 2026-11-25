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

  /// YouTube Music's own Mix for a seed video (the playlist whose id is
  /// `RDAMVM` followed by the seed video id).
  /// This is YouTube Music's radio pool — music-only, already filtered —
  /// unlike raw related videos, which are polluted with non-music. Returns
  /// an empty list when the Mix can't be fetched; callers must fall back
  /// to related videos / search. UNVERIFIED on a real network (the
  /// sandbox returned empty for every playlist fetch, Mix and control
  /// alike), so an empty result here proves nothing about the Mix.
  Future<List<Track>> fetchMixTracks(String seedVideoId) async {
    final id = seedVideoId.trim();
    if (id.isEmpty) return [];
    try {
      final videos = await _yt.playlists
          .getVideos('RDAMVM$id')
          .take(25)
          .timeout(const Duration(seconds: 20))
          .toList();
      return videos.map(_toTrack).toList();
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

/// Words in a title that mark a track as a remix, cover, or otherwise
/// altered version rather than the song itself. These are dropped from
/// radio mixes — the Mix itself contains remixes, so the filter is
/// needed even when the pool is YouTube Music's own. Matched as
/// substrings on the lowercased title.
const _radioDropWords = [
  'remix',
  'cover',
  'sped up',
  'slowed',
  '8d',
  'nightcore',
  'reverb',
  'slowed down',
];

/// Normalize an artist/channel name for comparison: lowercase, strip
/// non-alphanumerics, and drop channel suffixes (VEVO, Topic, Official,
/// Music) so "Joyner Lucas", "Joyner Lucas - Topic" and
/// "JoynerLucasVEVO" all match. The seed name gets the same treatment,
/// so the comparison is symmetric.
String _normalizeArtist(String name) {
  var n = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  for (final w in ['vevo', 'topic', 'official', 'music']) {
    n = n.replaceAll(w, '');
  }
  return n;
}

bool _sameArtist(String a, String b) {
  final na = _normalizeArtist(a);
  final nb = _normalizeArtist(b);
  if (na.isEmpty || nb.isEmpty) return false;
  if (na == nb) return true;
  return na.contains(nb) || nb.contains(na);
}

bool _isAlteredVersion(Track t) {
  final title = t.title.toLowerCase();
  return _radioDropWords.any((w) => title.contains(w));
}

/// Shape a radio candidate pool into a Spotify-like ratio, in Unbound's
/// own code. Pure selection/arrangement — no network, trivially
/// testable. Works on any pool (the Mix, related videos, search
/// results); the Mix is the best pool because YouTube Music already
/// filtered it to music.
///
/// Buckets, from the artist-radio deep dive:
///   (a) the seed artist — author/channel matches the seed;
///   (b) other artists, first half of the source order (YouTube ranked
///       these higher — the "same caliber" proxy);
///   (c) other artists, second half of the source order (the
///       "emerging / long tail" proxy).
/// The buckets are interleaved round-robin to roughly equal thirds,
/// never two in a row from the same artist. Within each bucket, tracks
/// are ranked by [affinityFor] when given (the local listening-stats
/// scorer — unplayed tracks score a 0.50 neutral prior, so they are
/// not buried); otherwise the source order stands. Up to three
/// [personalTracks] (liked / recently played) whose artist appears in
/// the radio's artist set are sprinkled in at spread positions, so the
/// radio feels like Daniel's, not a generic mix. Returns at most 25
/// tracks. Never ranks by view count — the stock library mangles it
/// ("1.2M views" parses to 12).
List<Track> shapeRadioMix(
  List<Track> candidates,
  String seedArtist, {
  double Function(Track)? affinityFor,
  List<Track> personalTracks = const [],
}) {
  // Dedupe by video ID, drop altered versions.
  final seen = <String>{};
  final clean = <Track>[];
  for (final t in candidates) {
    if (!seen.add(t.id)) continue;
    if (_isAlteredVersion(t)) continue;
    clean.add(t);
  }
  if (clean.isEmpty) return [];

  // Bucket A: seed artist. The rest split into B (first half, higher
  // in YouTube's order) and C (second half, long tail).
  final a = <Track>[];
  final others = <Track>[];
  for (final t in clean) {
    if (_sameArtist(t.artist, seedArtist)) {
      a.add(t);
    } else {
      others.add(t);
    }
  }
  final half = (others.length / 2).ceil();
  final b = others.sublist(0, half);
  final c = others.sublist(half);

  // Rank within each bucket by affinity (descending); source order is
  // the tiebreak (sort is stable, so equal scores keep their order).
  int rank(Track x, Track y) {
    if (affinityFor != null) {
      final d = affinityFor(y).compareTo(affinityFor(x));
      if (d != 0) return d;
    }
    return 0;
  }

  a.sort(rank);
  b.sort(rank);
  c.sort(rank);

  // Interleave A, B, C round-robin to roughly equal thirds. Never two
  // in a row from the same artist: buckets are disjoint by artist, so
  // consecutive picks from different buckets are always different
  // artists; when only one bucket still has tracks, skip past a
  // same-artist track and take the next different one.
  final buckets = [a, b, c];
  final indices = [0, 0, 0];
  final out = <Track>[];
  String? lastArtistKey;
  var progressed = true;
  while (progressed && out.length < 25) {
    progressed = false;
    for (var k = 0; k < buckets.length; k++) {
      if (out.length >= 25) break;
      final bucket = buckets[k];
      var i = indices[k];
      // Find the next track in this bucket from a different artist
      // than the last emitted track.
      while (i < bucket.length) {
        final key = _normalizeArtist(bucket[i].artist);
        if (lastArtistKey == null || key != lastArtistKey) break;
        i++;
      }
      if (i >= bucket.length) continue;
      final next = bucket[i];
      indices[k] = i + 1;
      out.add(next);
      lastArtistKey = _normalizeArtist(next.artist);
      progressed = true;
    }
  }
  // Any tracks left in a bucket that were skipped only because of the
  // same-artist guard are placed by cycling the buckets again,
  // preferring a track whose artist differs from the last emitted, so
  // the remainder is spread out instead of dumped one artist at a time.
  // Only when every remaining track is by the same artist as the last
  // emitted do we accept the adjacency — there is nothing else to play.
  final inOut = out.map((t) => t.id).toSet();
  while (out.length < 25) {
    var placed = false;
    for (final bucket in buckets) {
      if (out.length >= 25) break;
      var idx = -1;
      for (var i = 0; i < bucket.length; i++) {
        if (inOut.contains(bucket[i].id)) continue;
        final key = _normalizeArtist(bucket[i].artist);
        if (lastArtistKey == null || key != lastArtistKey) {
          idx = i;
          break;
        }
      }
      if (idx == -1) continue;
      out.add(bucket[idx]);
      inOut.add(bucket[idx].id);
      lastArtistKey = _normalizeArtist(bucket[idx].artist);
      placed = true;
    }
    if (!placed) {
      // Nothing left differs from the last emitted artist. Append the
      // rest in bucket order — the adjacency is unavoidable now.
      for (final bucket in buckets) {
        for (final t in bucket) {
          if (out.length >= 25) break;
          if (inOut.contains(t.id)) continue;
          out.add(t);
          inOut.add(t.id);
        }
        if (out.length >= 25) break;
      }
      break;
    }
  }

  // Personal layer: up to 3 liked/recent tracks whose artist is in the
  // radio's artist set, sprinkled at spread positions. Never duplicates
  // a track already in the mix.
  if (personalTracks.isNotEmpty) {
    final radioArtists = clean.map((t) => _normalizeArtist(t.artist)).toSet();
    final inMix = out.map((t) => t.id).toSet();
    final sprinkle = <Track>[];
    for (final t in personalTracks) {
      if (sprinkle.length >= 3) break;
      if (inMix.contains(t.id)) continue;
      if (_isAlteredVersion(t)) continue;
      if (!radioArtists.contains(_normalizeArtist(t.artist))) continue;
      sprinkle.add(t);
      inMix.add(t.id);
    }
    // Spread them through the mix (after track 4, then ~every 6).
    var insertAt = 4;
    for (final t in sprinkle) {
      if (out.length >= 25) break;
      final pos = insertAt.clamp(0, out.length);
      out.insert(pos, t);
      insertAt += 6;
    }
  }

  return out;
}
