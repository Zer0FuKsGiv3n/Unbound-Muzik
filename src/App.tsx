// Unbound Muzik — fresh rebuild, 2026-11-11.
//
// Built from the 14 approved decisions, not from the old code.
// The rules that matter most live here:
//   - Playback truth: `wantsPlaying` (what Daniel asked for — drives the
//     play/pause commands) is split from `isPlaying` (what YouTube
//     confirmed — true ONLY on a PLAYING event — drives the pause icon).
//     `isStarting` is derived: wantsPlaying && !isPlaying. The button
//     shows "Starting…" until YouTube confirms Playing; tapping while
//     Starting shows cancels the start.
//   - Queue end: Repeat On loops. Repeat Off ends in ONE clean, visible
//     finished state. No end-of-queue step ever depends on a network
//     fetch. Unplayable tracks are skipped; if every track fails in a
//     row, playback stops cleanly with a plain message.
//   - Library honesty: Recently Played is a real history, separate from
//     the queue. There is no fake "Downloads" — downloads will be real
//     files or they will not be called downloads. No dead Spotify import.
//     Subscriptions are not modelled as tracks.

import { useEffect, useRef, useState } from 'react';
import type { Playlist, SearchState, TabKey, Track } from './types';
import {
  createYoutubePlayer,
  type PlayerStateName,
  type YoutubePlayer,
} from './lib/youtubePlayer';
import {
  fetchArtistRadioTracks,
  searchTracks,
  SearchFailedError,
  SearchNotConfiguredError,
} from './lib/youtube';
import {
  getOwnRecommendations,
  getRecommendedTracks,
} from './lib/recommendations';
import {
  loadExternalRecommendations,
  loadLiked,
  loadPlaylists,
  loadRecentlyPlayed,
  loadRepeat,
  recordPlayed,
  saveExternalRecommendations,
  saveLiked,
  savePlaylists,
  saveRepeat,
} from './lib/storage';
import { coverDataUrl, coverGradient } from './lib/coverArt';

function formatDuration(seconds?: number): string {
  if (typeof seconds !== 'number' || Number.isNaN(seconds)) return '';
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, '0')}`;
}

function newId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

export default function App() {
  // --- Tabs ---
  const [tab, setTab] = useState<TabKey>('home');

  // --- Playback state (the truth split) ---
  const [queue, setQueue] = useState<Track[]>([]);
  const [currentIndex, setCurrentIndex] = useState(-1);
  const [wantsPlaying, setWantsPlaying] = useState(false);
  const [isPlaying, setIsPlaying] = useState(false);
  const [playerReady, setPlayerReady] = useState(false);
  const [playerError, setPlayerError] = useState<string | null>(null);
  const [queueEnded, setQueueEnded] = useState(false);
  const [repeatOn, setRepeatOn] = useState<boolean>(() => loadRepeat());

  // --- Library state ---
  const [liked, setLiked] = useState<Track[]>(() => loadLiked());
  const [recentlyPlayed, setRecentlyPlayed] = useState<Track[]>(() =>
    loadRecentlyPlayed(),
  );
  const [playlists, setPlaylists] = useState<Playlist[]>(() => loadPlaylists());

  // --- Radio state ---
  const [radioSeed, setRadioSeed] = useState<string | null>(null);
  const [radioLoading, setRadioLoading] = useState(false);
  const [radioArtist, setRadioArtist] = useState('');

  // --- Search state ---
  const [searchQuery, setSearchQuery] = useState('');
  const [searchState, setSearchState] = useState<SearchState>({ status: 'idle' });

  // --- Home recommendations ---
  const [externalRecs, setExternalRecs] = useState<boolean>(() =>
    loadExternalRecommendations(),
  );
  const [recommendations, setRecommendations] = useState<Track[]>([]);
  const [recsLoading, setRecsLoading] = useState(false);

  // --- Playlist saving ---
  const [playlistName, setPlaylistName] = useState('');
  const [notice, setNotice] = useState<string | null>(null);

  // --- Refs ---
  const playerRef = useRef<YoutubePlayer | null>(null);
  const consecutiveErrorsRef = useRef(0);
  const awaitingRadioRefillRef = useRef(false);
  const waitingForRefillRef = useRef(false);
  const pendingLoadRef = useRef<string | null>(null);
  // Every track the app has seen, by id — so playlists (which store ids)
  // can be played back later in the session.
  const knownTracksRef = useRef(new Map<string, Track>());

  const currentTrack: Track | null =
    currentIndex >= 0 && currentIndex < queue.length ? queue[currentIndex] : null;
  const isStarting = wantsPlaying && !isPlaying;

  function registerTracks(tracks: Track[]): void {
    for (const track of tracks) {
      knownTracksRef.current.set(track.id, track);
    }
  }

  // --- Core playback actions ---

  function playAt(index: number, list?: Track[], keepRadioSeed = false): void {
    const targetList = list ?? queue;
    if (index < 0 || index >= targetList.length) return;
    if (list && list !== queue) {
      setQueue(list);
      if (!keepRadioSeed) setRadioSeed(null);
    }
    setCurrentIndex(index);
    setQueueEnded(false);
    setPlayerError(null);
    consecutiveErrorsRef.current = 0;
    setWantsPlaying(true);
    const track = targetList[index];
    registerTracks([track]);
    if (track.source !== 'youtube') return;
    if (playerRef.current) {
      playerRef.current.load(track.id);
    } else {
      // Player still loading — load as soon as it is ready.
      pendingLoadRef.current = track.id;
      setPlayerError('The YouTube player is not ready yet. Try again in a moment.');
    }
  }

  function finishQueue(): void {
    setWantsPlaying(false);
    setIsPlaying(false);
    playerRef.current?.stop();
    setQueueEnded(true);
  }

  function handleTrackEnded(): void {
    if (queue.length === 0) return;
    if (currentIndex < queue.length - 1) {
      playAt(currentIndex + 1);
      return;
    }
    // Last track ended.
    if (awaitingRadioRefillRef.current) {
      // A radio refill is already on its way — wait for it instead of
      // ending. The refill plays the first new track when it lands.
      waitingForRefillRef.current = true;
      return;
    }
    if (repeatOn) {
      playAt(0);
      return;
    }
    finishQueue();
  }

  function handlePlayerError(message: string): void {
    if (queue.length === 0 || queueEnded) {
      setPlayerError(message);
      return;
    }
    setPlayerError(message);
    consecutiveErrorsRef.current += 1;
    if (consecutiveErrorsRef.current >= queue.length) {
      // Every track failed in a row. Stop cleanly with a plain message.
      setWantsPlaying(false);
      setIsPlaying(false);
      playerRef.current?.stop();
      setPlayerError(
        'None of the tracks in this queue could be played. Pick another track to try again.',
      );
      return;
    }
    // Skip the unplayable track.
    if (currentIndex < queue.length - 1) {
      playAt(currentIndex + 1);
    } else if (repeatOn) {
      playAt(0);
    } else {
      finishQueue();
    }
  }

  function handlePlayerState(state: PlayerStateName): void {
    if (state === 'PLAYING') {
      setIsPlaying(true);
      consecutiveErrorsRef.current = 0;
      setPlayerError(null);
      if (currentTrack) {
        // Real history: only a confirmed play counts as played.
        setRecentlyPlayed(recordPlayed(currentTrack));
      }
    } else if (state === 'PAUSED') {
      setIsPlaying(false);
    } else if (state === 'ENDED') {
      setIsPlaying(false);
      handleTrackEnded();
    }
    // BUFFERING / UNSTARTED / CUED change nothing — "Starting…" stays
    // visible until YouTube confirms Playing.
  }

  function playNext(): void {
    if (queue.length === 0) return;
    if (queueEnded) {
      playAt(0);
      return;
    }
    if (currentIndex < queue.length - 1) {
      playAt(currentIndex + 1);
    } else if (repeatOn) {
      playAt(0);
    } else {
      finishQueue();
    }
  }

  function playPrevious(): void {
    if (queue.length === 0) return;
    if (queueEnded) {
      // From the finished state, Previous goes to the track before the last.
      playAt(Math.max(0, queue.length - 2));
      return;
    }
    if (currentIndex > 0) {
      playAt(currentIndex - 1);
    } else {
      playAt(0);
    }
  }

  function togglePlay(): void {
    if (!currentTrack) {
      if (queue.length > 0) playAt(0);
      return;
    }
    if (isStarting) {
      // Tapping while "Starting…" shows cancels the start.
      setWantsPlaying(false);
      return;
    }
    setWantsPlaying(!wantsPlaying);
  }

  // --- Radio ---

  async function startRadio(artist: string): Promise<void> {
    const seed = artist.trim();
    if (!seed) return;
    setRadioLoading(true);
    setPlayerError(null);
    try {
      const tracks = await fetchArtistRadioTracks(seed);
      if (tracks.length === 0) {
        setPlayerError(
          `Couldn't start a radio station for "${seed}" — search may not be connected yet, or nothing was found.`,
        );
        return;
      }
      registerTracks(tracks);
      playAt(0, tracks, true);
      setRadioSeed(seed);
    } catch (err) {
      if (err instanceof SearchNotConfiguredError) {
        setPlayerError(
          `Radio needs search, and search isn't connected yet. The search service gets set up in Phase 2.`,
        );
      } else {
        setPlayerError(
          `Couldn't start a radio station for "${seed}". Try again in a moment.`,
        );
      }
    } finally {
      setRadioLoading(false);
    }
  }

  // Radio replenishment: when the current track is within 5 of the end of
  // a radio queue, fetch more in the background. Guarded by a ref so it
  // cannot race the last track — ENDED while a refill is in flight waits
  // for the refill instead of ending the queue.
  useEffect(() => {
    if (!radioSeed) return;
    if (queue.length === 0 || currentIndex < 0) return;
    if (queue.length - 1 - currentIndex > 5) return;
    if (awaitingRadioRefillRef.current) return;
    awaitingRadioRefillRef.current = true;
    const oldLength = queue.length;
    fetchArtistRadioTracks(radioSeed)
      .then((fresh) => {
        const known = new Set(queue.map((t) => t.id));
        const extra = fresh.filter((t) => !known.has(t.id));
        if (extra.length > 0) {
          registerTracks(extra);
          const grown = [...queue, ...extra];
          setQueue(grown);
          if (waitingForRefillRef.current) {
            waitingForRefillRef.current = false;
            playAt(oldLength, grown, true);
          }
        } else if (waitingForRefillRef.current) {
          waitingForRefillRef.current = false;
          if (repeatOn) playAt(0);
          else finishQueue();
        }
      })
      .catch(() => {
        // A failed refill must never break playback. The queue simply ends
        // normally when it runs out.
        if (waitingForRefillRef.current) {
          waitingForRefillRef.current = false;
          if (repeatOn) playAt(0);
          else finishQueue();
        }
      })
      .finally(() => {
        awaitingRadioRefillRef.current = false;
      });
    // Intentionally not depending on `queue` itself — the distance check
    // above is what matters, and depending on the whole queue would
    // re-trigger on every append.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentIndex, queue.length, radioSeed]);

  // --- Search ---

  async function handleSearch(query: string): Promise<void> {
    const q = query.trim();
    if (!q) return;
    setSearchState({ status: 'loading' });
    try {
      const tracks = await searchTracks(q);
      if (tracks.length === 0) {
        setSearchState({ status: 'empty', query: q });
      } else {
        registerTracks(tracks);
        setSearchState({ status: 'ready', tracks });
      }
    } catch (err) {
      if (err instanceof SearchNotConfiguredError) {
        setSearchState({ status: 'not-configured' });
      } else if (err instanceof SearchFailedError) {
        setSearchState({ status: 'error', message: err.message });
      } else {
        setSearchState({
          status: 'error',
          message: 'Search failed. Try again in a moment.',
        });
      }
    }
  }

  // --- Library actions ---

  function toggleLike(track: Track): void {
    const isLiked = liked.some((t) => t.id === track.id);
    const next = isLiked
      ? liked.filter((t) => t.id !== track.id)
      : [track, ...liked];
    setLiked(next);
    saveLiked(next);
  }

  function isLiked(track: Track): boolean {
    return liked.some((t) => t.id === track.id);
  }

  function toggleRepeat(): void {
    const next = !repeatOn;
    setRepeatOn(next);
    saveRepeat(next);
  }

  function saveQueueAsPlaylist(): void {
    const name = playlistName.trim();
    if (queue.length === 0) {
      setNotice('The queue is empty — play something first, then save it.');
      return;
    }
    if (!name) {
      setNotice('Give the playlist a name first.');
      return;
    }
    const playlist: Playlist = {
      id: newId(),
      title: name,
      trackIds: queue.map((t) => t.id),
      createdAt: Date.now(),
    };
    const next = [playlist, ...playlists];
    setPlaylists(next);
    savePlaylists(next);
    setPlaylistName('');
    setNotice(`Saved "${name}" with ${queue.length} songs.`);
  }

  function playPlaylist(playlist: Playlist): void {
    const tracks = playlist.trackIds
      .map((id) => knownTracksRef.current.get(id))
      .filter((t): t is Track => t !== undefined);
    if (tracks.length === 0) {
      setNotice(
        'Those songs are not in this session yet — play them from Search or Home first, then the playlist will work.',
      );
      return;
    }
    playAt(0, tracks);
    setTab('queue');
  }

  function deletePlaylist(id: string): void {
    const next = playlists.filter((p) => p.id !== id);
    setPlaylists(next);
    savePlaylists(next);
  }

  // --- Recommendations ---

  async function loadRecommendations(): Promise<void> {
    setRecsLoading(true);
    try {
      const playlistTracks = playlists
        .flatMap((p) => p.trackIds)
        .map((id) => knownTracksRef.current.get(id))
        .filter((t): t is Track => t !== undefined);
      const recs = await getRecommendedTracks(
        externalRecs,
        liked,
        recentlyPlayed,
        playlistTracks,
      );
      registerTracks(recs);
      setRecommendations(recs);
    } catch {
      // External recommendations failing must never break Home — fall
      // back to the local mix, which needs no network at all.
      setRecommendations(getOwnRecommendations(liked, recentlyPlayed, []));
    } finally {
      setRecsLoading(false);
    }
  }

  // --- Player setup (once) ---

  // The player callbacks always call the latest render's handlers.
  const actionsRef = useRef({
    handlePlayerState,
    handlePlayerError,
    playNext,
    playPrevious,
    togglePlay,
  });
  actionsRef.current = {
    handlePlayerState,
    handlePlayerError,
    playNext,
    playPrevious,
    togglePlay,
  };

  useEffect(() => {
    let cancelled = false;
    createYoutubePlayer('yt-player', {
      onStateChange: (state) => actionsRef.current.handlePlayerState(state),
      onError: (message) => actionsRef.current.handlePlayerError(message),
      onReady: () => {
        if (cancelled) return;
        setPlayerReady(true);
        if (pendingLoadRef.current && playerRef.current) {
          playerRef.current.load(pendingLoadRef.current);
          pendingLoadRef.current = null;
        }
      },
    })
      .then((player) => {
        if (cancelled) {
          player.destroy();
          return;
        }
        playerRef.current = player;
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          setPlayerError(
            err instanceof Error
              ? err.message
              : 'The YouTube player could not be loaded.',
          );
        }
      });
    return () => {
      cancelled = true;
      playerRef.current?.destroy();
      playerRef.current = null;
    };
  }, []);

  // The play/pause command: wantsPlaying alone drives it. isPlaying never
  // commands the player — it only labels the button.
  useEffect(() => {
    if (!playerReady || !currentTrack) return;
    if (currentTrack.source !== 'youtube') return;
    if (wantsPlaying) {
      playerRef.current?.play();
      playerRef.current?.unmuteIfNeeded();
    } else {
      playerRef.current?.pause();
    }
  }, [wantsPlaying, playerReady, currentTrack]);

  // Media Session: lock-screen / notification / headphone controls.
  // Best-effort — it labels and remote-controls; it does not play sound
  // or keep the page alive.
  useEffect(() => {
    if (!('mediaSession' in navigator)) return;
    try {
      navigator.mediaSession.setActionHandler('play', () => setWantsPlaying(true));
      navigator.mediaSession.setActionHandler('pause', () => setWantsPlaying(false));
      navigator.mediaSession.setActionHandler('previoustrack', () =>
        actionsRef.current.playPrevious(),
      );
      navigator.mediaSession.setActionHandler('nexttrack', () =>
        actionsRef.current.playNext(),
      );
    } catch {
      // Media Session handlers are best-effort.
    }
  }, []);

  useEffect(() => {
    if (!('mediaSession' in navigator) || !currentTrack) return;
    try {
      navigator.mediaSession.metadata = new MediaMetadata({
        title: currentTrack.title,
        artist: currentTrack.artist,
        artwork: [
          {
            src:
              currentTrack.thumb ||
              coverDataUrl(currentTrack.id + currentTrack.title),
            sizes: '256x256',
            type: 'image/png',
          },
        ],
      });
      navigator.mediaSession.playbackState = isPlaying ? 'playing' : 'paused';
    } catch {
      // Media Session metadata is best-effort.
    }
  }, [currentTrack, isPlaying]);

  // Load recommendations on first open.
  useEffect(() => {
    registerTracks(liked);
    registerTracks(recentlyPlayed);
    void loadRecommendations();
    // Only on mount — refreshes happen from the Refresh button and the
    // external-recommendations toggle.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // --- Render helpers ---

  const statusText = isPlaying
    ? 'Playing'
    : isStarting
      ? 'Starting…'
      : queueEnded
        ? 'Finished'
        : currentTrack
          ? 'Paused'
          : 'Nothing playing';

  function coverFor(track: Track, size: 'sm' | 'lg'): React.ReactNode {
    if (track.thumb) {
      return (
        <img
          className={size === 'lg' ? 'cover-lg' : 'cover-sm'}
          src={track.thumb}
          alt=""
          loading="lazy"
        />
      );
    }
    return (
      <div
        className={size === 'lg' ? 'cover-lg cover-drawn' : 'cover-sm cover-drawn'}
        style={{ background: coverGradient(track.id + track.title) }}
        aria-hidden="true"
      >
        <span>{track.title.charAt(0).toUpperCase()}</span>
      </div>
    );
  }

  function trackRow(track: Track, index: number, list: Track[]): React.ReactNode {
    const isCurrent = currentTrack?.id === track.id && list === queue;
    return (
      <li key={`${track.id}-${index}`} className={isCurrent ? 'row current' : 'row'}>
        <button
          className="row-play"
          type="button"
          onClick={() => playAt(index, list)}
          aria-label={`Play ${track.title} by ${track.artist}`}
        >
          {coverFor(track, 'sm')}
          <span className="row-text">
            <span className="row-title">{track.title}</span>
            <span className="row-artist">
              {track.artist}
              {formatDuration(track.duration) ? ` · ${formatDuration(track.duration)}` : ''}
            </span>
          </span>
          {isCurrent && isPlaying && (
            <span className="eq eq-playing" aria-hidden="true">
              <i />
              <i />
              <i />
              <i />
            </span>
          )}
        </button>
        <button
          className={isLiked(track) ? 'btn-like liked' : 'btn-like'}
          type="button"
          onClick={() => toggleLike(track)}
          aria-label={isLiked(track) ? `Unlike ${track.title}` : `Like ${track.title}`}
        >
          {isLiked(track) ? '♥ Liked' : '♡ Like'}
        </button>
      </li>
    );
  }

  return (
    <div className="app">
      <header className="topbar">
        <h1 className="wordmark">
          Unbound <span className="gradient-word">Music</span>
        </h1>
        <p className="tagline">Music, unbound from the ridiculousness.</p>
        <span className={`pill ${isPlaying ? 'pill-playing' : ''}`} aria-live="polite">
          <span className="pill-dot" aria-hidden="true" /> {statusText}
        </span>
      </header>

      <main className="content">
        {/* Now playing — glass card, always visible. */}
        <section className="now-playing" aria-label="Now playing">
          {currentTrack ? (
            <>
              {coverFor(currentTrack, 'lg')}
              <div className="now-text">
                <h2>{currentTrack.title}</h2>
                <p>{currentTrack.artist}</p>
                <span
                  className={`eq eq-big ${isPlaying ? 'eq-playing' : ''}`}
                  aria-hidden="true"
                >
                  <i />
                  <i />
                  <i />
                  <i />
                </span>
              </div>
            </>
          ) : (
            <div className="now-empty">
              <h2>Nothing playing yet</h2>
              <p>Search for a song, start a radio station, or pick a recommendation below.</p>
            </div>
          )}
        </section>

        {/* The YouTube player — compact, and NEVER hidden while playing. */}
        <section className="video-dock" aria-label="Video player">
          <div id="yt-player" className="yt-frame" />
          {!currentTrack && (
            <p className="dock-note">The player appears here when a song starts.</p>
          )}
        </section>

        {playerError && (
          <p className="error" role="alert">
            {playerError}
          </p>
        )}
        {queueEnded && (
          <p className="finished" role="status">
            Queue finished. Tap ▶ to play it again from the start.
          </p>
        )}
        {notice && (
          <p className="notice" role="status">
            {notice}
            <button type="button" onClick={() => setNotice(null)} aria-label="Dismiss">
              ✕
            </button>
          </p>
        )}

        {tab === 'home' && (
          <section aria-label="Home">
            <div className="section-head">
              <h2>Recommended for you</h2>
              <button
                className="btn btn-small"
                type="button"
                onClick={() => void loadRecommendations()}
                disabled={recsLoading}
              >
                {recsLoading ? 'Refreshing…' : 'Refresh'}
              </button>
            </div>
            <label className="toggle-row">
              <input
                type="checkbox"
                checked={externalRecs}
                onChange={(e) => {
                  const next = e.target.checked;
                  setExternalRecs(next);
                  saveExternalRecommendations(next);
                  void loadRecommendations();
                }}
              />
              <span>
                External recommendations — expand picks from YouTube related videos.
                Off means your own mix only: liked, recent, and playlists. No network.
              </span>
            </label>
            {recommendations.length === 0 && !recsLoading && (
              <p className="hint">
                Nothing to recommend yet — like a song or play one, and recommendations
                will appear here.
              </p>
            )}
            {recsLoading && recommendations.length === 0 && (
              <p className="hint">Finding recommendations…</p>
            )}
            <ul className="track-list">
              {recommendations.map((track, i) => trackRow(track, i, recommendations))}
            </ul>
            <p className="promise">
              Unbound is free forever. No ads from the app, no tracking, no account.
            </p>
          </section>
        )}

        {tab === 'search' && (
          <section aria-label="Search">
            <h2>Search</h2>
            <form
              className="search-form"
              onSubmit={(e) => {
                e.preventDefault();
                void handleSearch(searchQuery);
              }}
            >
              <input
                className="search-box"
                type="search"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="Song, artist, album…"
                aria-label="Search for music"
              />
              <button className="btn btn-primary" type="submit">
                Search
              </button>
            </form>
            {searchState.status === 'idle' && (
              <p className="hint">
                One box, no source to pick. When you search, it is instantly there or
                it is not.
              </p>
            )}
            {searchState.status === 'loading' && <p className="hint">Searching…</p>}
            {searchState.status === 'not-configured' && (
              <p className="hint">
                Search isn&apos;t connected yet. The search service gets set up in
                Phase 2 — your own API key and a tiny proxy. Nothing here is broken;
                it just isn&apos;t wired up yet.
              </p>
            )}
            {searchState.status === 'error' && (
              <p className="error" role="alert">
                {searchState.message}
              </p>
            )}
            {searchState.status === 'empty' && (
              <p className="hint">
                Nothing found for &ldquo;{searchState.query}&rdquo;. Try different words.
              </p>
            )}
            {searchState.status === 'ready' && (
              <ul className="track-list">
                {searchState.tracks.map((track, i) =>
                  trackRow(track, i, searchState.tracks),
                )}
              </ul>
            )}
          </section>
        )}

        {tab === 'library' && (
          <section aria-label="Library">
            <h2>Library</h2>

            <h3>Liked songs</h3>
            {liked.length === 0 ? (
              <p className="hint">No liked songs yet — tap ♡ Like on any song.</p>
            ) : (
              <ul className="track-list">
                {liked.map((track, i) => trackRow(track, i, liked))}
              </ul>
            )}

            <h3>Recently played</h3>
            {recentlyPlayed.length === 0 ? (
              <p className="hint">Nothing played yet — your real listening history will show here.</p>
            ) : (
              <ul className="track-list">
                {recentlyPlayed.map((track, i) =>
                  trackRow(track, i, recentlyPlayed),
                )}
              </ul>
            )}

            <h3>Playlists</h3>
            {playlists.length === 0 ? (
              <p className="hint">
                No playlists yet — save the current queue as a playlist from the Queue tab.
              </p>
            ) : (
              <ul className="playlist-list">
                {playlists.map((playlist) => (
                  <li key={playlist.id} className="row">
                    <button
                      className="row-play"
                      type="button"
                      onClick={() => playPlaylist(playlist)}
                    >
                      <span className="row-text">
                        <span className="row-title">{playlist.title}</span>
                        <span className="row-artist">
                          {playlist.trackIds.length} songs
                        </span>
                      </span>
                    </button>
                    <button
                      className="btn-like"
                      type="button"
                      onClick={() => deletePlaylist(playlist.id)}
                      aria-label={`Delete playlist ${playlist.title}`}
                    >
                      Delete
                    </button>
                  </li>
                ))}
              </ul>
            )}

            <h3>Downloads</h3>
            <p className="hint">
              No downloaded files yet. Downloads will be real files stored on this
              phone — that work comes in a later phase. Nothing here pretends to be a
              download.
            </p>
          </section>
        )}

        {tab === 'queue' && (
          <section aria-label="Queue">
            <div className="section-head">
              <h2>Queue</h2>
              <button className="btn btn-small" type="button" onClick={toggleRepeat}>
                Repeat: {repeatOn ? 'On' : 'Off'}
              </button>
            </div>
            {radioSeed && (
              <p className="hint">
                Radio station: {radioSeed} — new songs are added as you get near the end.
              </p>
            )}
            {queue.length === 0 ? (
              <p className="hint">
                The queue is empty. Search for a song or start a radio station to fill it.
              </p>
            ) : (
              <ul className="track-list">
                {queue.map((track, i) => trackRow(track, i, queue))}
              </ul>
            )}
            {queue.length > 0 && (
              <form
                className="playlist-save"
                onSubmit={(e) => {
                  e.preventDefault();
                  saveQueueAsPlaylist();
                }}
              >
                <input
                  className="search-box"
                  type="text"
                  value={playlistName}
                  onChange={(e) => setPlaylistName(e.target.value)}
                  placeholder="Name this playlist…"
                  aria-label="Playlist name"
                />
                <button className="btn" type="submit">
                  Save queue as playlist
                </button>
              </form>
            )}
          </section>
        )}

        {tab === 'radio' && (
          <section aria-label="Radio">
            <h2>Artist radio</h2>
            <p className="hint">
              Pick an artist and keep listening. Radio is built from search results
              for now — the real related-videos radio comes with the APK.
            </p>
            <form
              className="search-form"
              onSubmit={(e) => {
                e.preventDefault();
                void startRadio(radioArtist);
              }}
            >
              <input
                className="search-box"
                type="text"
                value={radioArtist}
                onChange={(e) => setRadioArtist(e.target.value)}
                placeholder="Artist name…"
                aria-label="Artist for radio"
              />
              <button
                className="btn btn-primary"
                type="submit"
                disabled={radioLoading || !radioArtist.trim()}
              >
                {radioLoading ? 'Starting radio…' : 'Start Radio'}
              </button>
            </form>
            {radioSeed && (
              <p className="hint">
                Now playing station: <strong>{radioSeed}</strong>
              </p>
            )}
          </section>
        )}
      </main>

      {/* Player bar — glass, fixed at the bottom. */}
      <footer className="player-bar" aria-label="Player controls">
        <div className="player-track">
          {currentTrack ? coverFor(currentTrack, 'sm') : <div className="cover-sm cover-empty" aria-hidden="true" />}
          <span className="player-text">
            <span className="player-title">{currentTrack?.title ?? 'Nothing playing'}</span>
            <span className="player-artist">{currentTrack?.artist ?? 'Unbound Muzik'}</span>
          </span>
        </div>
        <div className="player-controls">
          <button
            className="btn-round"
            type="button"
            onClick={playPrevious}
            disabled={!currentTrack}
            aria-label="Previous track"
          >
            ⏮
          </button>
          <button
            className="btn-round btn-play"
            type="button"
            onClick={togglePlay}
            disabled={!currentTrack && queue.length === 0}
            aria-label={
              isStarting ? 'Cancel starting' : isPlaying ? 'Pause' : 'Play'
            }
          >
            {isStarting ? 'Starting…' : isPlaying ? '❚❚' : '▶'}
          </button>
          <button
            className="btn-round"
            type="button"
            onClick={playNext}
            disabled={!currentTrack}
            aria-label="Next track"
          >
            ⏭
          </button>
        </div>
      </footer>

      {/* Bottom tabs — five only. */}
      <nav className="tabbar" aria-label="Sections">
        {(
          [
            ['home', 'Home'],
            ['search', 'Search'],
            ['library', 'Library'],
            ['queue', 'Queue'],
            ['radio', 'Radio'],
          ] as [TabKey, string][]
        ).map(([key, label]) => (
          <button
            key={key}
            type="button"
            className={tab === key ? 'tab active' : 'tab'}
            onClick={() => setTab(key)}
            aria-current={tab === key ? 'page' : undefined}
          >
            {label}
          </button>
        ))}
      </nav>
    </div>
  );
}
