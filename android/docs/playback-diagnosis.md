# Unbound Muzik (APK) — Playback Diagnosis Playbook

Filed 2026-11-12. This is the durable record of how the APK's playback
pipeline works, what breaks it, how to tell what broke, and what is
baked in so the same failure does not come back. Written after tracing
Unbound's and Musify's playback paths side by side (2026-11-12) and
finding the real divergences — not by copying Musify, but by following
the mechanism each divergence reveals.

## The pipeline (what happens when Daniel taps a song)

1. **Search** — `_yt.search.search(q)` (`lib/services/youtube_service.dart`,
   `searchTracks`). Same call Musify makes. If results appear, this step
   is fine.
2. **Manifest fetch** — `_getBestAudioStream` loops `_streamClients`
   (`[visionOs, androidVr, androidSdkless, ios, android]`), calling
   `getManifest(videoId, ytClients: [client])` with a 20s timeout each.
   The first client that returns a manifest wins; its identity is
   recorded in `_songClients[videoId]`.
3. **Stream selection** — `_selectAudioStream` picks one audio-only
   stream from the manifest (see "Stream selection" below).
4. **Audio source build** — `_loadCurrent`
   (`lib/services/audio_handler.dart`) builds
   `AudioSource.uri(url, headers: streamPlaybackHeaders(videoId))`.
   The headers carry the minting client's User-Agent.
5. **Player load** — `await _player.setAudioSource(source)` (30s
   timeout), then `_player.play()` if the user still wants to play.
6. **Sound** — `isPlaying` becomes true only when just_audio confirms
   it. The EQ bars move only while `isPlaying` is true. The status
   pill reads Playing / Starting… / Paused / Finished from
   `wantsPlaying` vs `isPlaying`.

## Symptom → cause map (read the symptom, find the cause)

| What Daniel sees | What it means | Where to look |
|---|---|---|
| Stuck on "Starting…" (three dots), no error box, no EQ bars, never changes | `setAudioSource` never completed. ExoPlayer is retrying a bad URL internally and the load Future never resolves. Before the 30s timeout existed, there was no exit from this state. | The URL or its headers (wrong client, stale URL, undecodable format). See Divergence 1. |
| Cycling through songs, then "None of the tracks in this queue could be played" | `getManifest` threw for every client (usually 403s). The stock library's HEAD validation uses a desktop-Chrome User-Agent, so a valid URL can 403 *inside* `getManifest`. | The client list (two fallbacks are documented-dead: androidVr, androidSdkless). See Divergence 2. |
| Red error box: "YouTube refused that song (403)" | The stream URL was refused at fetch time (wrong/missing User-Agent, or the client is blocked). | `streamPlaybackHeaders` — which client minted the URL and whether its User-Agent was sent. |
| Red error box: "YouTube is rate-limiting this connection" | YouTube thinks too many requests came from this IP (shared egress / CGNAT). Not a bad song — skipping tracks will not help. | Wait it out. Do not cycle the queue. |
| Red error box: "That took too long" | A load timed out (30s on `setAudioSource`, 20s on `getManifest`). The retry already ran once for the same song. | Connection, or the client that minted the URL. |
| Pill says Playing, EQ bars move, but no sound | The player thinks it is playing. This is a player/output fault, not a stream fault. | Audio session, output device, volume. Not the stream path. |

## The divergences found (2026-11-12 trace) and what each one taught

### 1. No timeout on `setAudioSource` — the hang (highest impact)
- **Musify:** `setAudioSource(...).timeout(30s)`; on timeout it retries
  the same song once with a freshly minted URL.
- **Unbound (before the fix):** a bare `await _player.setAudioSource(source)`.
  No timeout, no retry. ExoPlayer retries a bad URL internally and the
  Future never completes, so no exception is ever thrown, no error box
  appears, and the UI sits on "Starting…" forever. The idle-guard in
  `_onPlayerState` also suppresses the error path while `_resolving`
  is true, so there was no exit at all.
- **Fix logic (in Unbound's own code):** put a bounded timeout on the
  load and treat a timeout as a load failure that triggers the existing
  error path — plus one same-song retry with a freshly minted URL
  before skipping. Implemented in `_loadCurrent`
  (`lib/services/audio_handler.dart`) and `invalidateStreamFor`
  (`lib/services/youtube_service.dart`).
- **Prevention baked in:** the timeout is now part of `_loadCurrent`
  itself. A load can never hang the UI silently again — it either
  plays, errors with a plain message, or skips after one retry.

### 2. Stock library HEAD-checks the URL with the wrong User-Agent
- **Musify's vendored library:** after fetching streams, `getManifest`
  HEAD-checks `streams.first.url` *with the minting client's headers*.
  Only a 403 with the correct headers rejects the client.
- **Stock youtube_explode_dart 3.1.0:** the HEAD check is
  `_httpClient.head(url)` with **no headers** — a desktop-Chrome
  User-Agent. A perfectly valid visionOs/androidSdkless URL can 403
  inside `getManifest`, and Unbound treats that client as failed.
- **Fix logic:** validate (or re-mint) the URL with the minting
  client's headers before handing it to the player, so a bad URL
  fails fast with an error instead of hanging the player. The 30s
  timeout (Divergence 1) is the safety net for any URL that still
  slips through; the client order (visionOs first, which carries a
  User-Agent) is the first line of defence.
- **Note:** two of Unbound's fallbacks are documented-dead in the
  vendored library's own comments — androidVr "403s all of its
  formats as of 2026-08-17" and androidSdkless "blocked as of 2026".
  They only cost time (up to 20s each) before the error surfaces.
  They are kept as last-resort fallbacks, not relied on.

### 3. Stream selection had no codec/container filter
- **Musify:** `selectAudioOnlyStreamForQuality` drops Dolby codecs
  (`ec-3`, `ac-3`, `eac3`, score 0), prefers `mp4a`/`aac` in mp4/m4a
  (score 3), then `opus`/`vorbis` (score 2), then highest bitrate of
  the compatible pool.
- **Unbound (before the fix):** `audioOnly.withHighestBitrate()` with
  no filter. The highest-bitrate stream can be a Dolby format that
  ExoPlayer cannot decode, which stalls the load.
- **Fix logic:** filter the same way, in Unbound's own
  `_selectAudioStream` (`lib/services/youtube_service.dart`).
  Most YouTube audio is opus/mp4a so this is not the most likely
  cause, but the player must never be handed a format it cannot play.

### 4. No same-song fresh-URL retry
- **Musify:** on a load failure it invalidates the cached stream URL,
  fetches a brand-new manifest + URL, and retries the **same song
  once** before skipping.
- **Unbound (before the fix):** `_handlePlaybackError` skipped to the
  next track. A dead/stale URL was treated as a bad song and the queue
  burned through.
- **Fix logic:** one fresh-URL retry for the same song before
  skipping (implemented in `_loadCurrent`). A stale URL is
  recoverable by re-minting; skipping treats a transient URL fault
  as a bad song.
- **Note:** this also explains Musify's close/reopen "fix" for
  cycling — reopening re-fetches fresh URLs. There is no network
  handling in either app; the fix for a stale URL on either side is
  a fresh manifest fetch.

### 5. Default load control (low impact)
- **Musify:** explicit `AndroidLoadControl` — max buffer 60s, start
  after 500ms buffered, resume after 3s rebuffered.
- **Unbound (before the fix):** stock `AudioPlayer()` defaults
  (2.5s to start, 5s to resume after rebuffer).
- **Fix logic:** set the same load-control values when constructing
  the player (`lib/services/audio_handler.dart`). Slower stall
  recovery, not a cause of the initial silence — but it makes
  recovery visibly faster.

### 6. No preload of the next song's URL (low impact)
- **Musify:** preloads the next song's stream URL while the current
  one plays.
- **Unbound:** no preload; the URL is fetched only when the track
  starts.
- **Fix logic:** not implemented yet — it only hides latency for
  subsequent tracks and cannot cause or fix the first track's
  silence. Filed here so it is not forgotten.

## Known robustness gaps (filed 2026-11-13 — things that can still bite)

These are breakage sources the playback trace did not cover, because
they live outside the stream pipeline. Filed so a future failure
lands on a known suspect instead of a fresh mystery.

### Samsung battery optimization can kill the foreground service
- **What:** Samsung's battery optimization ("Sleeping apps" / "Deep
  sleeping apps") can restrict background work even for a foreground
  service. The A16 is a Samsung, so this is a real risk, not a
  theoretical one.
- **Symptom if it bites:** playback stops when the phone has been
  idle a while, or the service dies after the screen has been off
  for a long stretch — even though it played fine while the phone
  was in use.
- **Mitigation:** exempt Unbound from battery optimization
  (Settings > Apps > Unbound Muzik > Battery > Unrestricted).
  **Mitigated in practice: Daniel grants the battery exemption (and
  full permissions) on every reinstall — stated 2026-11-13.** So
  this only bites if a reinstall happens without the exemption
  being re-applied.

### Notification permission (POST_NOTIFICATIONS) not yet prompted
- **What:** Android 13+ needs a runtime grant to show
  notifications. The permission is declared in the manifest, but
  nothing in the app asks for it yet.
- **Symptom if it bites:** the foreground service runs, but its
  notification (and the lock-screen / notification-shade playback
  controls) never appears. Daniel gets sound but no controls
  outside the app.
- **Mitigated in practice: Daniel grants full permissions on every
  reinstall — stated 2026-11-13.** The in-app prompt is still
  worth adding for robustness (a fresh install without the manual
  grant would hit this), but it is not currently biting.

### Audio focus — explicit resume added (2026-11-13)
- **What:** incoming call, another app playing audio, a navigation
  prompt. `AudioSessionConfiguration.music()` is set, so just_audio
  should pause or duck — but it had never been verified on the
  device.
- **What the library actually does (verified in just_audio 0.10.6
  source):** it subscribes to the interruption stream itself. On
  interruption begin (pause/unknown type) while playing, it pauses
  and records that it was interrupted. On interruption end it
  resumes — but ONLY when the type was reported as `pause`. An
  `unknown`-type interruption clears the flag without resuming, so
  the player can sit paused after a call even though the user still
  wants it playing. Becoming-noisy (headphones unplugged) pauses
  and never resumes — that is correct behaviour, not a gap.
- **Fix (Daniel's principle — better to have it and not need it):
  Unbound now has its OWN explicit interruption handler in
  `UnboundAudioHandler` (`lib/services/audio_handler.dart`): on
  interruption end, if `_wantsPlaying` is true and the player is
  not already playing, it resumes through the handler's own
  `play()`. If just_audio already resumed, the player is playing
  and this is a no-op, so it cannot double-resume. If the user
  paused during the call, `_wantsPlaying` is false and it stays
  paused — user intent is respected. Becoming-noisy is deliberately
  NOT auto-resumed.
- **Test:** start a song, have someone call, see whether it pauses
  during the call and resumes after hanging up.

### Bluetooth / headphone disconnect untested
- **What:** when Bluetooth headphones disconnect (or wired
  headphones are unplugged), playback should pause instead of
  blasting from the phone speaker. The audio session should handle
  the "becoming noisy" event — unverified.
- **Test:** play through Bluetooth, turn the headphones off, see
  whether it pauses or keeps playing out loud.

### Downloads untested end to end
- **What:** `downloads_service` saves real files
  (`tracks/<id>.m4a`) using the stream headers, but nobody has
  downloaded a song and played it offline yet.
- **Test:** download a track, turn on airplane mode, play it from
  the Library Downloads section.

### Lock-screen controls untested (APK)
- **What:** `audio_service` provides MediaSession controls, but
  whether they show correctly on the A16 lock screen and
  notification shade has not been verified. (Phase 0 Test 2 was
  for the web app, not the APK.)

### Web body: background playback and search still open
- **What:** the web app's IFrame background playback (Phase 0
  Test 1) is still unverified, and web search does not work yet —
  `SEARCH_PROXY_URL` is empty until Phase 2 (Daniel's API key +
  Cloudflare Worker) is done.

### Thin fallback chain if visionOs is blocked
- **What:** if YouTube blocks visionOs, the only real fallbacks
  left are ios and android — androidVr and androidSdkless are
  documented-dead. The client list looks like five deep but is
  effectively three, and two of those need PO tokens.
- **Watch for:** cycling + "None of the tracks" after a period
  of working fine. Check yt-dlp's client list first.

## What does NOT diverge (verified same, so not the cause)

- Search (`yt.search.search` in both).
- The header-passing mechanism itself: both send the minting client's
  User-Agent to `AudioSource.uri`. (Unbound passes headers for all
  streamed URLs — a superset, not a fault.)
- Audio session (`AudioSessionConfiguration.music()` in both),
  foreground service, `YoutubeExplode()` with no JS solver in both.
- The Innertube player-request path is structurally identical in
  both library copies.
- Network-change handling: neither app has any. A stream URL is
  minted for a client/network; if the network changes the URL can go
  stale. The fix on either side is a fresh manifest fetch.

## Where to find fixes (sources, in order of authority)

1. **yt-dlp** (`github.com/yt-dlp/yt-dlp`, `yt_dlp/extractor/youtube/_base.py`)
   — the public, authoritative list of Innertube clients, their
   parameters, and which ones need PO tokens. The visionOs client
   defined in Unbound's `youtube_service.dart` comes from here, not
   from any app. When YouTube changes its clients, this is the first
   place to look.
2. **youtube_explode_dart** (pub.dev, stock 3.1.0) — the library
   Unbound uses. Its `stream_client.dart` (`getManifest`) and
   `youtube_api_client.dart` (client definitions) are the two files
   that matter. Known stock-library gaps vs the vendored copy:
   the HEAD validation UA (Divergence 2) and the missing visionOs
   client (defined in-file instead).
3. **Musify** (`github.com/gokadzev/Musify`, public repo) — a
   *reference for mechanisms*, not a source to copy. Read it to
   understand *why* something works (its vendored library's comments
   document client breakages with dates), then implement the logic
   in Unbound's own code. Never vendor its library — that would make
   Unbound Musify with a different name, which violates the
   originality rule.
4. **YoutubeExplode issue #933** — PO-token enforcement breaking
   Innertube clients; the reason androidVr was tried first and why
   visionOs is preferred now.
5. **just_audio / ExoPlayer docs** — `setAudioSource` only completes
   when ExoPlayer reaches a ready state; a bad URL makes it retry
   internally instead of failing. That is why a timeout is mandatory.

## How to diagnose a new playback issue (the steps)

1. **Get the symptom exactly.** Pill text (Playing / Starting… /
   Paused / Finished), EQ bars moving or not, red error box exact
   words. Use the symptom → cause map above.
2. **Locate the step.** Stuck loading = Step 5 (player load).
   Cycling + "None of the tracks" = Step 2 (manifest). 403 box =
   Step 4 (headers/client). Playing + EQ + no sound = output, not
   stream.
3. **Check the client first.** Which client minted the URL
   (`_songClients`)? Does it carry a User-Agent? Is it on the
   documented-dead list (androidVr, androidSdkless)? Try visionOs.
4. **Check the stream.** Is the selected codec Dolby? Is the URL
   fresh or stale (network changed since minting)? Re-mint once.
5. **Check the player.** Did `setAudioSource` complete within 30s?
   If not, the timeout should have fired — if it did not, the
   timeout itself is broken, not the stream.
6. **If the mechanism is unclear, trace it.** Read the two library
   copies (`~/.pub-cache/.../youtube_explode_dart-3.1.0/` and a
   fresh Musify clone) side by side for the step in question, and
   yt-dlp for the client definitions. Do not guess from memory.
7. **File it here.** Add the symptom, the cause, and the fix to
   this playbook, and bake the prevention into the code — a timeout,
   a filter, a retry, or a fallback — so the same failure cannot
   recur silently.
