// Unbound Muzik — shared data model.
// One model for both bodies (web app and, later, the APK), so a like on
// the web is a like in the APK. No account is ever required to hold it
// together. Export/import first; real sync only if it proves necessary.

export interface Track {
  /** YouTube video ID (11 characters) for YouTube tracks. */
  id: string;
  title: string;
  artist: string;
  /** Thumbnail URL. May be empty — the UI draws a gradient cover then. */
  thumb: string;
  /** Duration in seconds, when known. */
  duration?: number;
  source: 'youtube' | 'local';
}

export interface Playlist {
  id: string;
  title: string;
  trackIds: string[];
  createdAt: number;
}

export type TabKey = 'home' | 'search' | 'library' | 'queue' | 'radio';

/** What a search can honestly report. Never a silent empty list. */
export type SearchState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'ready'; tracks: Track[] }
  | { status: 'empty'; query: string }
  | { status: 'not-configured' }
  | { status: 'error'; message: string };
