# Unbound Muzik — fresh rebuild

Personal music player PWA. Free and ad-free forever, for one person.
Built from scratch 2026-11-11 after the old repo was torn down by Daniel's
order. No code was copied from the old app — this is a fresh build from the
approved design decisions.

## What it is

- **Five tabs:** Home, Search, Library, Queue, Radio.
- **Playback:** visible YouTube IFrame player (audio-first UI, compact dock,
  never hidden). Playback truth built in from the start: `wantsPlaying`
  (what you asked for) is split from `isPlaying` (what YouTube confirmed).
  The button shows "Starting…" until YouTube confirms Playing; tapping
  while Starting cancels the start.
- **Queue:** Repeat On loops; Repeat Off ends in one clean, visible finished
  state. Unplayable tracks are skipped; if every track fails, playback stops
  cleanly with a plain message. Radio refills near the end of the queue,
  guarded so it cannot race the last track.
- **Library honesty:** Recently Played is a real history, separate from the
  queue. There is no fake "Downloads" — downloads will be real files or they
  will not be called downloads. No dead Spotify import.
- **Search:** one box, wired to one configurable proxy endpoint
  (`SEARCH_PROXY_URL` in `src/lib/youtube.ts`). The proxy is set up in
  Phase 2; until then the app says so honestly. A search that finds nothing
  says so; a search that fails says so. Never a silent empty list.
- **Design:** void `#050505`, ink `#0b0b12`, violet `#8b5cf6`, sky `#38bdf8`,
  mint `#34d399`. Space Grotesk headlines, Inter body. Frosted glass on the
  now-playing card and player bar only. Equalizer bars tied to real playback
  state. No 3D, no scroll-jacking, no fake content.

## Run it

```bash
npm install
npm run dev      # local development
npm run build    # typecheck + production build
```

## What it will never do

No ads from the app, no tracking, no account wall, no paywall — ever.
The official lane (visible IFrame player + official Data API search) is the
default. The grey-area machinery lives in the APK, not here.
