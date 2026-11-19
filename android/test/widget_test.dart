// Unbound Music — unit tests for the shared data model.
// The model is shared between the web app and the APK (Decision 14),
// so a round-trip here proves the JSON the two bodies exchange stays
// compatible.

import 'package:flutter_test/flutter_test.dart';
import 'package:unbound_music/models/track.dart';

void main() {
  test('Track survives a JSON round-trip', () {
    const track = Track(
      id: 'TLAuRp3xFTE',
      title: 'Seventeen',
      artist: 'Joyner Lucas',
      thumb: 'https://example.invalid/thumb.jpg',
      duration: 225,
    );
    final restored = Track.fromJson(track.toJson());
    expect(restored.id, 'TLAuRp3xFTE');
    expect(restored.title, 'Seventeen');
    expect(restored.artist, 'Joyner Lucas');
    expect(restored.thumb, 'https://example.invalid/thumb.jpg');
    expect(restored.duration, 225);
    expect(restored.source, TrackSource.youtube);
  });

  test('Playlist stores track ids, not tracks', () {
    const playlist = Playlist(
      id: 'p1',
      title: 'Test',
      trackIds: ['a', 'b', 'c'],
      createdAt: 0,
    );
    final restored = Playlist.fromJson(playlist.toJson());
    expect(restored.trackIds, ['a', 'b', 'c']);
  });

  test('formatDuration renders minutes and seconds', () {
    expect(formatDuration(null), '');
    expect(formatDuration(0), '0:00');
    expect(formatDuration(65), '1:05');
    expect(formatDuration(225), '3:45');
  });
}
