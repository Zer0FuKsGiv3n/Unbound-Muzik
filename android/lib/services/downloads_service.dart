// Unbound Muzik — downloads as real files.
//
// Only files actually on disk are called downloads. A download is the
// highest-bitrate audio-only stream for a track, saved under
// <app documents>/downloads/<videoId>.<container>.
// Nothing here pretends: the Library's Downloads section lists exactly
// the files in that folder that the app still knows about.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'youtube_service.dart';

class DownloadsService {
  DownloadsService(this._yt);

  final YoutubeService _yt;

  Future<Directory> get _downloadsDir async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/downloads');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> get _coversDir async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/covers');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// The local cover file for a track, if it has been downloaded.
  /// Covers live in a `covers` folder under the app documents
  /// directory, named by video id with a `.jpg` extension — a sibling
  /// of `downloads/`, never mixed in with the audio files.
  Future<File?> coverFileFor(Track track) async {
    final dir = await _coversDir;
    final file = File('${dir.path}/${track.id}.jpg');
    return await file.exists() ? file : null;
  }

  /// Download the best-available cover for a track (maxres → sd → hq),
  /// saving it under the app documents `covers` folder, named by video
  /// id with a `.jpg` extension. Returns the file, or null if
  /// no candidate could be fetched. Returns the cached file immediately
  /// if it already exists. Never throws — a missing cover is not an
  /// error, the remote thumbnail is the fallback. Never use maxres
  /// blindly: it 404s on many videos (older or SD-only uploads), so each
  /// candidate is tried in order and the first HTTP 200 wins.
  Future<File?> ensureCover(Track track) async {
    try {
      final existing = await coverFileFor(track);
      if (existing != null) return existing;
      final dir = await _coversDir;
      final candidates = [
        'https://i.ytimg.com/vi/${track.id}/maxresdefault.jpg',
        'https://i.ytimg.com/vi/${track.id}/sddefault.jpg',
        'https://i.ytimg.com/vi/${track.id}/hqdefault.jpg',
      ];
      final client = http.Client();
      try {
        for (final url in candidates) {
          try {
            final response = await client
                .get(Uri.parse(url))
                .timeout(const Duration(seconds: 15));
            if (response.statusCode == 200 &&
                response.bodyBytes.isNotEmpty) {
              final file = File('${dir.path}/${track.id}.jpg');
              await file.writeAsBytes(response.bodyBytes);
              return file;
            }
          } catch (_) {
            // Try the next candidate.
          }
        }
      } finally {
        client.close();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// The file a downloaded track would live in, if it is downloaded.
  Future<File?> fileFor(Track track) async {
    final dir = await _downloadsDir;
    for (final name in ['${track.id}.mp4', '${track.id}.webm']) {
      final file = File('${dir.path}/$name');
      if (await file.exists()) return file;
    }
    return null;
  }

  Future<bool> isDownloaded(Track track) async =>
      await fileFor(track) != null;

  /// Download a track's audio. Returns the saved file. Throws on failure.
  /// [onProgress] gets 0.0–1.0 as bytes arrive (null total = unknown).
  Future<File> downloadTrack(
    Track track, {
    void Function(double? progress)? onProgress,
  }) async {
    final stream = await _yt.getAudioStream(track.id);
    final dir = await _downloadsDir;
    final file = File('${dir.path}/${track.id}.${stream.container}');
    final client = http.Client();
    try {
      final request = http.Request('GET', stream.url);
      // Same rule as playback: send the minting client's headers, or
      // googlevideo.com answers 403.
      request.headers.addAll(stream.headers);
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw Exception(
          'Download failed (HTTP ${response.statusCode}). Try again.',
        );
      }
      final total = response.contentLength;
      var received = 0;
      final sink = file.openWrite();
      await for (final chunk in response.stream) {
        received += chunk.length;
        sink.add(chunk);
        if (onProgress != null) {
          onProgress(total != null && total > 0 ? received / total : null);
        }
      }
      await sink.close();
      return file;
    } finally {
      client.close();
    }
  }

  /// Every downloaded file, as (track, file) pairs — only files the app
  /// still has a track record for. Files without a known track are
  /// ignored, not shown as mystery entries.
  Future<List<({Track track, File file})>> downloadedTracks(
    Map<String, Track> trackCache,
  ) async {
    final dir = await _downloadsDir;
    final out = <({Track track, File file})>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.path.split('/').last;
      final id = name.split('.').first;
      final track = trackCache[id];
      if (track != null) out.add((track: track, file: entity));
    }
    return out;
  }

  Future<void> deleteDownload(Track track) async {
    final file = await fileFor(track);
    if (file != null && await file.exists()) {
      await file.delete();
    }
  }
}
