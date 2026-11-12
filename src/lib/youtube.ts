// Unbound Muzik — search, through ONE configurable proxy endpoint.
//
// The old Base44 proxy is dead by decision. The new proxy (a small
// Cloudflare Worker holding Daniel's own YouTube Data API key, Phase 2)
// gets its URL filled in here, in this one place, when Phase 2 runs.
// Until then the app says so honestly instead of pretending search works.
//
// The proxy contract (what the Worker must answer):
//   GET {SEARCH_PROXY_URL}?q=<search text>
//   -> 200 { "results": [{ "id", "title", "artist", "thumb", "duration" }] }
// Any non-200 answer, or a network failure, is reported as an error —
// never as a silent empty list.

import type { Track } from '../types';

/** Phase 2 fills this in with the Cloudflare Worker URL. Empty = not set up yet. */
export const SEARCH_PROXY_URL = '';

export class SearchNotConfiguredError extends Error {
  constructor() {
    super('Search is not connected yet.');
    this.name = 'SearchNotConfiguredError';
  }
}

export class SearchFailedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SearchFailedError';
  }
}

interface ProxyResult {
  id: string;
  title: string;
  artist?: string;
  thumb?: string;
  duration?: number;
}

interface ProxyResponse {
  results?: ProxyResult[];
  error?: string;
}

function toTrack(r: ProxyResult): Track | null {
  if (!r.id || !r.title) return null;
  return {
    id: r.id,
    title: r.title,
    artist: r.artist || 'Unknown artist',
    thumb: r.thumb || '',
    duration: typeof r.duration === 'number' ? r.duration : undefined,
    source: 'youtube',
  };
}

/**
 * Search YouTube through the configured proxy. Throws
 * SearchNotConfiguredError when the proxy URL is empty, and
 * SearchFailedError when the request fails or the answer is unusable.
 * Never returns a silent empty list on failure — callers must show the
 * error to Daniel in plain words.
 */
export async function searchTracks(query: string): Promise<Track[]> {
  const q = query.trim();
  if (!q) return [];
  if (!SEARCH_PROXY_URL) {
    throw new SearchNotConfiguredError();
  }
  let response: Response;
  try {
    response = await fetch(
      `${SEARCH_PROXY_URL}?q=${encodeURIComponent(q)}`,
      { signal: AbortSignal.timeout(15000) },
    );
  } catch {
    throw new SearchFailedError(
      "Couldn't reach the search service — check your connection and try again.",
    );
  }
  if (!response.ok) {
    if (response.status === 403) {
      throw new SearchFailedError(
        'Search was refused (403). The search service may need its key or quota checked.',
      );
    }
    if (response.status === 429) {
      throw new SearchFailedError(
        'Search is used up for today (quota). Try again tomorrow.',
      );
    }
    throw new SearchFailedError(
      `Search failed (HTTP ${response.status}). Try again in a moment.`,
    );
  }
  let data: ProxyResponse;
  try {
    data = (await response.json()) as ProxyResponse;
  } catch {
    throw new SearchFailedError(
      'The search service answered in a way the app could not read. Try again.',
    );
  }
  if (data.error) {
    throw new SearchFailedError(data.error);
  }
  const tracks = (data.results || []).map(toTrack).filter((t): t is Track => t !== null);
  return tracks;
}

/**
 * Simulated artist radio: three searches ("{artist} music", "{artist} songs",
 * "{artist} official video"), de-duplicated, shuffled, stop at 20.
 * This is a simulation — it borrows search, not YouTube's real related-videos
 * graph. The real graph belongs to the APK's grey lane (Decision 7).
 */
export async function fetchArtistRadioTracks(artist: string): Promise<Track[]> {
  const seed = artist.trim();
  if (!seed) return [];
  const queries = [`${seed} music`, `${seed} songs`, `${seed} official video`];
  const seen = new Set<string>();
  const out: Track[] = [];
  for (const q of queries) {
    if (out.length >= 20) break;
    let results: Track[];
    try {
      results = await searchTracks(q);
    } catch {
      // One failed radio search must not kill the whole station.
      continue;
    }
    for (const track of results) {
      if (seen.has(track.id)) continue;
      seen.add(track.id);
      out.push(track);
      if (out.length >= 20) break;
    }
  }
  // Shuffle so the station does not always start with the same song.
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}
