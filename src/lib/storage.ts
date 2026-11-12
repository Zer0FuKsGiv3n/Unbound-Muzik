// Unbound Muzik — local persistence.
// Everything here is Daniel's own data, on his own phone, in his own
// browser. No account, no server copy, no tracking. localStorage is for
// small lists only (liked songs, recent plays, settings). Song files, when
// they exist one day, belong in OPFS — never here.

import type { Playlist, Track } from '../types';

const LIKED_KEY = 'unbound.liked';
const RECENT_KEY = 'unbound.recentlyPlayed';
const REPEAT_KEY = 'unbound.repeatQueue';
const EXTERNAL_REC_KEY = 'unbound.externalRecommendations';
const PLAYLISTS_KEY = 'unbound.playlists';

const MAX_RECENT = 20;

function readJson<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return fallback;
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function writeJson(key: string, value: unknown): void {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Storage full or unavailable — the app keeps working in memory.
  }
}

export function loadLiked(): Track[] {
  return readJson<Track[]>(LIKED_KEY, []);
}

export function saveLiked(tracks: Track[]): void {
  writeJson(LIKED_KEY, tracks);
}

export function loadPlaylists(): Playlist[] {
  return readJson<Playlist[]>(PLAYLISTS_KEY, []);
}

export function savePlaylists(playlists: Playlist[]): void {
  writeJson(PLAYLISTS_KEY, playlists);
}

/**
 * Recently Played — a REAL history of what was played, newest first.
 * This is not the queue. It only grows when a track is actually confirmed
 * playing, and it is capped at 20 entries.
 */
export function loadRecentlyPlayed(): Track[] {
  return readJson<Track[]>(RECENT_KEY, []);
}

export function recordPlayed(track: Track): Track[] {
  const recent = loadRecentlyPlayed().filter((t) => t.id !== track.id);
  recent.unshift(track);
  const trimmed = recent.slice(0, MAX_RECENT);
  writeJson(RECENT_KEY, trimmed);
  return trimmed;
}

/** Repeat the queue when it ends. Saved, default On. */
export function loadRepeat(): boolean {
  const raw = localStorage.getItem(REPEAT_KEY);
  return raw === null ? true : raw === 'true';
}

export function saveRepeat(value: boolean): void {
  try {
    localStorage.setItem(REPEAT_KEY, String(value));
  } catch {
    // Keep working in memory.
  }
}

/** "External recommendations" — expand home picks from YouTube related videos. Default off. */
export function loadExternalRecommendations(): boolean {
  return localStorage.getItem(EXTERNAL_REC_KEY) === 'true';
}

export function saveExternalRecommendations(value: boolean): void {
  try {
    localStorage.setItem(EXTERNAL_REC_KEY, String(value));
  } catch {
    // Keep working in memory.
  }
}
