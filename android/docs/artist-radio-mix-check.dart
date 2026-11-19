// Temporary live verification for the artist-radio deep dive.
// Checks: (1) RDAMVM Mix returns tracks, (2) Mix looks music-only,
// (3) related-videos view counts are mangled (e.g. 1.2M -> 12).
// Run: dart --packages=.dart_tool/package_config.json docs/artist-radio-mix-check.dart
// (from the project root)
import 'dart:async';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main() async {
  final yt = YoutubeExplode();
  const seed = 'TLAuRp3xFTE'; // Joyner Lucas - "Seventeen"
  try {
    print('== CHECK 1+2: RDAMVM Mix ==');
    final mix = await yt.playlists
        .getVideos('RDAMVM$seed')
        .take(25)
        .toList()
        .timeout(const Duration(seconds: 60));
    print('MIX COUNT: ${mix.length}');
    for (var i = 0; i < mix.length; i++) {
      final v = mix[i];
      print('${i + 1}. ${v.title} | ${v.author} | id=${v.id} | views=${v.engagement.viewCount}');
    }
    print('== CHECK 3: related videos view counts ==');
    final seedVideo = await yt.videos.get(seed).timeout(const Duration(seconds: 60));
    final related = await yt.videos
        .getRelatedVideos(seedVideo)
        .timeout(const Duration(seconds: 60));
    print('RELATED COUNT: ${related?.length}');
    var suspicious = 0;
    for (final v in (related ?? []).take(15)) {
      final vc = v.engagement.viewCount;
      if (vc < 1000) suspicious++;
      print('  ${v.title} | ${v.author} | views=$vc');
    }
    print('SUSPICIOUS (views<1000 on popular related): $suspicious of 15');
  } catch (e) {
    print('ERROR: $e');
  } finally {
    yt.close();
  }
}
