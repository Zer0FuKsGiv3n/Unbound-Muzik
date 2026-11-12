// Unbound Muzik — YouTube IFrame player wrapper, dependency-free.
//
// The player is YouTube's own official embeddable player, loaded from
// youtube.com/iframe_api. It is always VISIBLE while playing (compact dock,
// never hidden) — a hidden player would break YouTube's terms and Daniel's
// own rule. The wrapper only translates YouTube's states and errors into
// plain words; it never decides what "playing" means. That decision lives
// in App.tsx (wantsPlaying vs isPlaying — the playback-truth split).

export type PlayerStateName =
  | 'UNSTARTED'
  | 'ENDED'
  | 'PLAYING'
  | 'PAUSED'
  | 'BUFFERING'
  | 'CUED';

export interface PlayerCallbacks {
  onStateChange: (state: PlayerStateName) => void;
  onError: (message: string) => void;
  onReady: () => void;
}

const YT_API_URL = 'https://www.youtube.com/iframe_api';

const ERROR_MESSAGES: Record<number, string> = {
  2: 'That video could not be loaded — the video ID is not valid.',
  5: 'That video could not be played in this player.',
  100: 'That video was not found, or it is private.',
  101: 'The owner of that video does not allow it to play embedded here.',
  150: 'The owner of that video does not allow it to play embedded here.',
};

declare global {
  interface Window {
    YT?: {
      Player: new (
        elementId: string,
        config: Record<string, unknown>,
      ) => {
        playVideo: () => void;
        pauseVideo: () => void;
        stopVideo: () => void;
        loadVideoById: (videoId: string) => void;
        getPlayerState: () => number;
        setVolume: (volume: number) => void;
        isMuted: () => boolean;
        unMute: () => void;
        destroy: () => void;
      };
      PlayerState: {
        UNSTARTED: number;
        ENDED: number;
        PLAYING: number;
        PAUSED: number;
        BUFFERING: number;
        CUED: number;
      };
    };
    onYouTubeIframeAPIReady?: () => void;
  }
}

let apiLoading: Promise<void> | null = null;

function loadApi(): Promise<void> {
  if (window.YT?.Player) return Promise.resolve();
  if (apiLoading) return apiLoading;
  apiLoading = new Promise<void>((resolve, reject) => {
    const previous = window.onYouTubeIframeAPIReady;
    window.onYouTubeIframeAPIReady = () => {
      if (previous) previous();
      resolve();
    };
    const script = document.createElement('script');
    script.src = YT_API_URL;
    script.async = true;
    script.onerror = () => reject(new Error('Failed to load the YouTube IFrame API.'));
    document.head.appendChild(script);
    // If the API was already loaded by another path, the callback may
    // never fire — resolve as soon as YT.Player appears.
    const check = window.setInterval(() => {
      if (window.YT?.Player) {
        window.clearInterval(check);
        resolve();
      }
    }, 200);
    window.setTimeout(() => window.clearInterval(check), 15000);
  });
  return apiLoading;
}

export interface YoutubePlayer {
  load(videoId: string): void;
  play(): void;
  pause(): void;
  stop(): void;
  unmuteIfNeeded(): void;
  destroy(): void;
}

/**
 * Create the player inside the element with the given id. The element must
 * already exist in the page. One player is kept alive across tracks —
 * loading a new video into the same player, not rebuilding it.
 */
export async function createYoutubePlayer(
  elementId: string,
  callbacks: PlayerCallbacks,
): Promise<YoutubePlayer> {
  await loadApi();
  const YT = window.YT;
  if (!YT?.Player) {
    throw new Error('Failed to load the YouTube IFrame API.');
  }
  const stateName = (code: number): PlayerStateName => {
    switch (code) {
      case YT.PlayerState.ENDED:
        return 'ENDED';
      case YT.PlayerState.PLAYING:
        return 'PLAYING';
      case YT.PlayerState.PAUSED:
        return 'PAUSED';
      case YT.PlayerState.BUFFERING:
        return 'BUFFERING';
      case YT.PlayerState.CUED:
        return 'CUED';
      default:
        return 'UNSTARTED';
    }
  };
  const player = new YT.Player(elementId, {
    height: '100%',
    width: '100%',
    playerVars: {
      playsinline: 1,
      rel: 0,
      modestbranding: 1,
    },
    events: {
      onReady: () => callbacks.onReady(),
      onStateChange: (event: { data: number }) => {
        callbacks.onStateChange(stateName(event.data));
      },
      onError: (event: { data: number }) => {
        const message =
          ERROR_MESSAGES[event.data] ||
          'That video could not be played (YouTube error ' + event.data + ').';
        callbacks.onError(message);
      },
    },
  });
  return {
    load(videoId: string) {
      player.loadVideoById(videoId);
    },
    play() {
      player.playVideo();
    },
    pause() {
      player.pauseVideo();
    },
    stop() {
      player.stopVideo();
    },
    unmuteIfNeeded() {
      try {
        if (player.isMuted()) player.unMute();
      } catch {
        // Player not ready yet — nothing to do.
      }
    },
    destroy() {
      try {
        player.destroy();
      } catch {
        // Already gone.
      }
    },
  };
}
