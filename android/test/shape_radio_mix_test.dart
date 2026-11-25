// Unit test for shapeRadioMix (radio ratio shaping).
// Run: flutter test test/shape_radio_mix_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:unbound_music/models/track.dart';
import 'package:unbound_music/services/youtube_service.dart';

Track t(String id, String title, String artist) =>
    Track(id: id, title: title, artist: artist, source: TrackSource.youtube);

void main() {
  test('shapes a balanced pool into roughly equal thirds', () {
    // 8 seed + 8 same-caliber + 8 emerging = a pool the shaping can
    // actually ratio. The seed artist must not dominate the mix.
    final candidates = <Track>[];
    for (var i = 0; i < 8; i++) {
      candidates.add(t('seed$i', 'Song $i', 'Joyner Lucas'));
    }
    for (var i = 0; i < 8; i++) {
      candidates.add(t('b$i', 'Other $i', 'Kendrick Lamar'));
    }
    for (var i = 0; i < 8; i++) {
      candidates.add(t('c$i', 'Third $i', 'Logic'));
    }
    final out = shapeRadioMix(candidates, 'Joyner Lucas');
    expect(out.length, 24);
    final seedCount =
        out.where((x) => x.artist == 'Joyner Lucas').length;
    // Roughly a third, not a majority.
    expect(seedCount, lessThanOrEqualTo(9));
    expect(seedCount, greaterThanOrEqualTo(7));
    // No two in a row from the same artist.
    for (var i = 1; i < out.length; i++) {
      expect(out[i].artist, isNot(out[i - 1].artist));
    }
  });

  test('a seed-heavy pool is spread out, not clumped', () {
    // Mimic the real Mix check: 22 of 25 are the seed artist.
    // Arrangement alone cannot ratio a pool this lopsided (the pool
    // has to be enriched first — see startRadio), but the seed tracks
    // must be spread through the mix, with variety up front, not 22
    // in a row.
    final candidates = <Track>[];
    for (var i = 0; i < 22; i++) {
      candidates.add(t('seed$i', 'Song $i', 'Joyner Lucas'));
    }
    candidates.add(t('b1', 'Other One', 'Kendrick Lamar'));
    candidates.add(t('b2', 'Other Two', 'J. Cole'));
    candidates.add(t('b3', 'Other Three', 'Logic'));
    final out = shapeRadioMix(candidates, 'Joyner Lucas');
    expect(out.length, 25);
    // Variety up front: the first 6 tracks include a non-seed artist.
    final firstSix = out.sublist(0, 6);
    expect(
      firstSix.any((x) => x.artist != 'Joyner Lucas'),
      isTrue,
    );
    // The seed tracks are not all clumped at the front: the first
    // two tracks are from different artists.
    expect(out[0].artist, isNot(out[1].artist));
  });

  test('drops remixes/covers and dedupes', () {
    final candidates = [
      t('a', 'Seventeen', 'Joyner Lucas'),
      t('b', 'Seventeen (Remix)', 'Joyner Lucas'),
      t('c', 'Song (Cover)', 'Someone Else'),
      t('a', 'Seventeen', 'Joyner Lucas'), // duplicate id
      t('d', 'Real Song', 'J. Cole'),
      t('e', 'Sped Up Song', 'Logic'),
    ];
    final out = shapeRadioMix(candidates, 'Joyner Lucas');
    final ids = out.map((x) => x.id).toSet();
    expect(ids, isNot(contains('b')));
    expect(ids, isNot(contains('c')));
    expect(ids, isNot(contains('e')));
    expect(ids.length, out.length); // no duplicates
    expect(ids, contains('a'));
    expect(ids, contains('d'));
  });

  test('matches the seed artist across channel-name variants', () {
    final candidates = [
      t('a', 'Song A', 'Joyner Lucas - Topic'),
      t('b', 'Song B', 'JoynerLucasVEVO'),
      t('c', 'Song C', 'J. Cole'),
      t('d', 'Song D', 'Logic'),
      t('e', 'Song E', 'Kendrick Lamar'),
      t('f', 'Song F', 'Eminem'),
    ];
    final out = shapeRadioMix(candidates, 'Joyner Lucas');
    // The two seed-artist variants should be treated as the seed bucket
    // and spread through the mix, not clumped at the front.
    final seedIdx = [
      for (var i = 0; i < out.length; i++)
        if (out[i].id == 'a' || out[i].id == 'b') i,
    ];
    expect(seedIdx.length, 2);
    expect(seedIdx[1] - seedIdx[0], greaterThan(1));
  });

  test('sprinkles personal tracks whose artist is in the radio set', () {
    final candidates = [
      for (var i = 0; i < 12; i++) t('s$i', 'Seed $i', 'Joyner Lucas'),
      for (var i = 0; i < 6; i++) t('o$i', 'Other $i', 'J. Cole'),
      for (var i = 0; i < 6; i++) t('p$i', 'Third $i', 'Logic'),
    ];
    final personal = [
      t('liked1', 'Liked Cole Song', 'J. Cole'),
      t('liked2', 'Liked Other', 'Someone Not In Radio'),
    ];
    final out = shapeRadioMix(
      candidates,
      'Joyner Lucas',
      personalTracks: personal,
    );
    expect(out.map((x) => x.id), contains('liked1'));
    expect(out.map((x) => x.id), isNot(contains('liked2')));
  });

  test('affinity ranks within a bucket, source order is the tiebreak', () {
    final candidates = [
      t('a', 'Seed A', 'Joyner Lucas'),
      t('b', 'Other High', 'J. Cole'),
      t('c', 'Other Low', 'J. Cole'),
      t('d', 'Third', 'Logic'),
    ];
    final out = shapeRadioMix(
      candidates,
      'Joyner Lucas',
      affinityFor: (track) => track.id == 'b' ? 0.9 : 0.1,
    );
    // 'b' (high affinity) should come before 'c' (low affinity) among
    // the non-seed artists.
    expect(
      out.indexWhere((x) => x.id == 'b'),
      lessThan(out.indexWhere((x) => x.id == 'c')),
    );
  });
}
