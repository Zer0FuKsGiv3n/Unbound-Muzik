# Items 3–7 implementation checklist (elite roadmap)

Filed 2026-11-17 while the items 1+2 APK builds. Execute after that build
finishes and verifies — do NOT edit lib/ while a build is running (the
Dart compile reads the sources mid-build).

## Item 3 — High-Res Notification Artwork

- `lib/services/downloads_service.dart`: add `coverFileFor(Track)` (sync:
  returns the File if `<docs>/covers/<id>.jpg` exists, else null) and
  `ensureCover(Track)` (async: try maxres → sd → hq by HTTP status/first
  200 wins, save bytes to `<docs>/covers/<id>.jpg`, return File or null).
  Build candidate URLs from `track.id` directly:
  `https://i.ytimg.com/vi/<id>/maxresdefault.jpg`,
  `.../sddefault.jpg`, `.../hqdefault.jpg`. Never use maxres blindly
  (404s on many videos). Covers live in `covers/`, a sibling of
  `downloads/`, not mixed in.
- `lib/services/audio_handler.dart` `_emit()`: artUri = local cover file
  if `coverFileFor` finds one → `Uri.file(path)`; else remote
  `track.thumb` → `Uri.parse`; else null. Apply to BOTH the current-item
  MediaItem and the queue MediaItems. Trigger `ensureCover` when a track
  starts (in `_loadCurrent` / `playAt`); when it lands for the current
  track, call `_emit()` again so audio_service re-sends the MediaItem.
- `lib/main.dart` AudioServiceConfig: add `artDownscaleWidth: 512,
  artDownscaleHeight: 512` (512 is the sweet spot; a 1280×720 bitmap
  decodes to ~3.7 MB otherwise).
- Note: Android Auto + file:// art is unconfirmed (may be empty there);
  phone notification is the target. Remote hqdefault stays the fallback.

## Item 4 — Audio Becoming Noisy Handler

- `lib/services/audio_handler.dart` constructor, inside the existing
  `AudioSession.instance.then(...)` block next to the interruption
  listener: add `session.becomingNoisyEventStream.listen((_) {
  unawaited(pause()); });`. Must route through the handler's own
  `pause()` (clears `_wantsPlaying`), NOT `_player.pause()` — otherwise
  the interruption-end listener would resume through the phone speaker
  on the next focus regain. No manifest change (audio_session registers
  the receiver dynamically). No change to `pause()` itself.

## Item 5 — Edge-to-Edge Safe Areas

- `lib/main.dart` `main()`: after `WidgetsFlutterBinding
  .ensureInitialized()`, add
  `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);`
  (import `package:flutter/services.dart`).
- `lib/theme/unbound_theme.dart`: add `static const
  SystemUiOverlayStyle systemUiOverlayStyle =
  SystemUiOverlayStyle.light.copyWith(statusBarColor:
  Colors.transparent, statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark, systemNavigationBarColor:
  Colors.transparent, systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarContrastEnforced: false);` (import services.dart
  if the theme file doesn't already expose it).
- `lib/main.dart` HomeShell: wrap the `Scaffold` in
  `AnnotatedRegion<SystemUiOverlayStyle>(value:
  UnboundTheme.systemUiOverlayStyle, child: Scaffold(...))`. Change the
  body `SafeArea` to `SafeArea(top: true, bottom: false)`. Do NOT wrap
  the bottomNavigationBar in a SafeArea — the stock BottomNavigationBar
  already adds the bottom inset itself (verified in Flutter SDK source).
  Leave `extendBody` false. The sheet's maxChildSize 0.95 already clears
  the status bar; no extra SafeArea in the sheet.

## Item 6 — Native Haptics (built-in HapticFeedback only, no new dep)

- `android/app/src/main/AndroidManifest.xml`: add
  `<uses-permission android:name="android.permission.VIBRATE"/>`
  (normal permission, auto-granted; verify in the merged manifest).
- `lib/widgets/widgets.dart`: import `package:flutter/services.dart`.
  PlayerBar play/pause, skip-previous, skip-next onPressed: first line
  `HapticFeedback.lightImpact();` (fire-and-forget, no await).
- `lib/widgets/widgets.dart` SeekBar: add detents — `onChangeStart`:
  `mediumImpact()`; `onChanged`: `selectionClick()` ONLY when crossing
  a whole-second boundary (track `_lastHapticSecond` in state, start
  1s, tune to 5s if busy); `onChangeEnd`: `lightImpact()` + seek.
  Never fire a haptic from the position StreamBuilder.
- `lib/widgets/now_playing_sheet.dart`: same `lightImpact()` on the
  transport buttons (play/pause, prev, next, like, repeat) and collapse.
- Tab change: do NOT add a manual haptic yet — test on device first
  whether BottomNavigationBar.enableFeedback already ticks; adding one
  blind risks double-firing. Note as an on-phone check.

## Item 7 — On-Device Smart Queue Refill

- New model `lib/models/track_stats.dart`: `TrackStats` with
  toJson/fromJson — trackId, artist, playCount (starts ≥5s), completions
  (natural end OR ratio ≥0.80), earlySkips (user next/prev, ratio <0.25
  AND listened <30s), lateSkips, totalListenSeconds, lastListenedSeconds,
  lastPlayedAtMs, liked. No title/thumb in the record.
- New scorer `lib/services/affinity.dart`: `double trackAffinity
  (TrackStats? stats, {required bool liked})` — bounded 0–1 formula:
  completionRate = (completions+1)/(starts+2) [Laplace], playTerm =
  ln(1+playCount)/ln(1+10), likeTerm, recency = 0.5^(days/30),
  skipRate = earlySkips/max(1,starts); affinity = clamp(0.40*compRate +
  0.20*playTerm + 0.20*likeTerm + 0.20*recency − 0.25*skipRate, 0, 1).
  Unplayed → 0.50 neutral prior. Shared by handler + recommendations.
- `lib/services/storage_service.dart`: in-memory `Map<String,
  TrackStats>`, load at startup from SharedPreferences key
  `listening_stats_v1`, debounced persist (≤ once per 30s + on pause),
  prune to 500 (drop oldest lastPlayedAtMs among unliked; liked never
  pruned). Add `recordListenOutcome({required Track track, required
  ListenOutcome outcome, required int listenedSeconds, int?
  durationSeconds})` and `statsFor(String id)`. Keep the 20-item Recent
  list untouched.
- `lib/services/audio_handler.dart`: classify outcomes. Natural end
  (`ProcessingState.completed` → `_handleTrackEnded`): record
  completion for the track that just ended, BEFORE advancing. User
  `skipToNext`/`skipToPrevious`: capture `_player.position` at that
  moment, classify early (<30s AND ratio <0.25) vs late skip, record,
  then proceed. App killed/paused mid-track: record partial listen
  (adds to totalListenSeconds, counts as a start, neither completion
  nor skip) via `onTaskRemoved`/`stop()`. Thresholds: early skip =
  listened <30s AND ratio <0.25; completion = natural end OR ratio
  ≥0.80; tracks <30s can never be early-skipped (a <30s track played
  to the end is a completion). If `Track.duration` is null, use
  absolute thresholds only (listened ≥240s = completion, <30s = early
  skip), never divide by null.
- `lib/services/audio_handler.dart` `_maybeRefill`: after fetching the
  candidate pool, group by artist, rank WITHIN each artist group by
  `affinity()`, interleave groups round-robin, reserve every 6th
  appended slot for the highest-ranked unplayed candidate (ε≈0.15
  exploration). Never let affinity re-weight bucket sizes. Note: the
  full `shapeRadioMix` (remix/cover/live filter, equal-thirds) from the
  artist-radio work is a separate pending piece — this is the minimal
  artist-grouped ranking, not the full shaping.
- `lib/services/recommendations.dart`: reuse the same `affinity()`
  scorer for the own-mix / Quick Picks paths; keep opt-in external
  mode unchanged.
- Do NOT score on every position update — score once per refill from
  the in-memory map. Do NOT add a DB (sqflite/drift) — SharedPreferences
  JSON map is enough at this scale (hundreds of records).

## After items 3–7: verify, then build the wow APK

- `flutter analyze` clean, then `flutter build apk --debug
  --no-android-gradle-daemon`. Verify size/sha1/aapt. The wow APK is
  items 1–7 + the held interruption fix. Do NOT send it until Daniel
  confirms. Gapless (playlist API, the second half of item 2) is a
  follow-up after seek is verified working on the phone.
