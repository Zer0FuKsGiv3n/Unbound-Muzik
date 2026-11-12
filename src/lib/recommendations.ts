// Unbound Muzik — recommendations.
// Two modes, exactly like the Musify "magic if" that Daniel asked for:
//   - Own mix (default): liked + recently played + a sample of playlists,
//     shuffled, no network. Instant, always works.
//   - External (opt-in): expand the 5 most recent seeds through artist
//     radio search, scored by position x recency, top 15. Borrowed
//     intelligence, only when asked for.
// Search is never touched by this switch. Tapping a recommendation only
// changes the queue when Daniel taps it.

import type { Track } from '../types';
import { fetchArtistRadioTracks } from './youtube';

function shuffle<T>(items: T[]): T[] {
  const copy = [...items];
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy;
}

export function getOwnRecommendations(
  liked: Track[],
  recentlyPlayed: Track[],
  playlistTracks: Track[],
  count = 15,
): Track[] {
  const seen = new Set<string>();
  const pool: Track[] = [];
  for (const track of [...liked, ...recentlyPlayed, ...playlistTracks]) {
    if (seen.has(track.id)) continue;
    seen.add(track.id);
    pool.push(track);
  }
  return shuffle(pool).slice(0, count);
}

export async function getExternalRecommendations(
  recentlyPlayed: Track[],
  count = 15,
): Promise<Track[]> {
  const seeds = recentlyPlayed.slice(0, 5);
  if (seeds.length === 0) return [];
  const scored = new Map<string, { track: Track; score: number }>();
  for (let seedIndex = 0; seedIndex < seeds.length; seedIndex++) {
    const seed = seeds[seedIndex];
    const recencyWeight = seeds.length - seedIndex;
    let batch: Track[];
    try {
      batch = await fetchArtistRadioTracks(seed.artist || seed.title);
    } catch {
      continue;
    }
    batch.slice(0, 8).forEach((track, position) => {
      const positionWeight = 8 - position;
      const score = positionWeight * recencyWeight;
      const existing = scored.get(track.id);
      if (!existing || score > existing.score) {
        scored.set(track.id, { track, score });
      }
    });
  }
  return [...scored.values()]
    .sort((a, b) => b.score - a.score)
    .slice(0, count)
    .map((entry) => entry.track);
}

export async function getRecommendedTracks(
  external: boolean,
  liked: Track[],
  recentlyPlayed: Track[],
  playlistTracks: Track[],
): Promise<Track[]> {
  const own = getOwnRecommendations(liked, recentlyPlayed, playlistTracks);
  if (!external) return own;
  const ext = await getExternalRecommendations(recentlyPlayed);
  return ext.length > 0 ? ext : own;
}
