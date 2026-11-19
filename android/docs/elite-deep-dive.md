# Elite deep dive — Unbound Muzik APK (Flutter)

Filed 2026-11-16. Research only — no app code was changed. This report is the
research behind the 7 upgrades in the elite roadmap
(`docs/wow-version-spec.md`, section "Elite roadmap"). It covers the
recommended approach, concrete code patterns, gotchas, and the exact
integration points for each item.

**Versions this report is grounded in** (from `pubspec.lock`, verified):
just_audio **0.10.6**, audio_service **0.18.19**, audio_session **0.2.4**,
youtube_explode_dart **3.1.0**, shared_preferences **2.5.5**, rxdart **0.28.0**
(transitive — present in the lock file but not a direct dependency),
Flutter **3.35.7**, Dart **3.9.2**, targetSdk = `flutter.targetSdkVersion`
(API 35 / Android 15). Device: Samsung Galaxy A16 5G.

**How it was researched:** four parallel research passes over open-source
platforms, developer forums, official docs, and the installed package
sources in `~/.pub-cache` — plus direct verification of the load-bearing
claims against those installed sources (just_audio, audio_service,
audio_session, youtube_explode_dart, Flutter SDK) and the Unbound codebase
itself. Where a claim comes from a library's own source, the file and line
are cited. Where something could not be verified, it is said plainly in
"What was NOT verified" at the end.

## Read this first — four premises in the brief were wrong

These change what the work actually is. They were found by reading the code
and the installed library sources, not by guessing.

1. **Item 3 premise is wrong: the app does NOT save covers to
   `artworks/<id>.jpg`.** `grep` finds zero references to `artworks/` anywhere
   in `lib/`. `DownloadsService` (`lib/services/downloads_service.dart`)
   only writes audio files to `downloads/<id>.mp4|.webm`. Cover downloading
   is **new work**, not a matter of pointing `artUri` at an existing file.
   (The `artworks/` layout is Musify's, not Unbound's.)
2. **Item 5 premise is wrong: edge-to-edge is already on.** Flutter 3.35.7
   + targetSdk 35 means `SystemUiMode.edgeToEdge` is the default — the
   Flutter SDK source says so explicitly (`system_chrome.dart`: "Flutter
   apps use [SystemUiMode.edgeToEdge] by default"). The work is inset
   handling and icon brightness, not enabling edge-to-edge.
3. **Item 2 premise needs a correction: `PlaybackState` has no `position`
   constructor parameter.** It has `updatePosition`, and the audio_service
   docs say explicitly **not** to push it continuously — the OS projects the
   position forward from `updatePosition`/`updateTime`/`speed` while
   playing. The fix is to set `updatePosition` on discontinuities only
   (seek, track change, pause). Also, the notification seek bar only
   appears if `MediaItem.duration` is set.
4. **Gapless: `ConcatenatingAudioSource` IS deprecated in just_audio
   0.10.6** — verified in the installed source
   (`just_audio.dart:2921`, `@Deprecated('Use AudioPlayer.setAudioSources
   instead')`; changelog line 40). The gapless path is
   `AudioPlayer.setAudioSources` (the playlist API), not the deprecated
   class.

## 1. Full-Screen Now Playing Sheet

### Recommended approach

Use a **persistent `DraggableScrollableSheet` in a `Stack` in the
`Scaffold.body` of `HomeShell`**, NOT `showModalBottomSheet`. A modal sheet
is a route — it dims and barriers the content behind it, takes over
back-button handling, and is dismissed rather than collapsed. That is the
wrong model for a persistent mini-player the user browses away from and back
to. The persistent variant is the Spotify-style idiom: the sheet stays
docked while the user browses the tabs.

Open-source precedent is split, which is itself informative. Musify and
Spotube both use a full-page player (a Navigator-pushed `NowPlayingPage` /
`PlayerView`) plus a separate floating mini-player — the common open-source
Flutter idiom. The sheet wins for Unbound because Daniel wants Spotify-grade
flow and the mini-player must stay alive across all five tabs without a
route push/pop — but it is a choice, not the only proven pattern. If the
sheet proves fiddly, the fallback is the Musify/Spotube model: tap the
mini-player, push a full-screen `NowPlayingPage` route, keep the mini-player
mounted underneath.

Sizing: sizes are **fractions of the parent's height** (0.0–1.0). Suggested
snap points: the mini-player fraction, ~0.55 (half — artwork + controls),
and ~0.92–1.0 (full). Do **not** hard-code the mini fraction (e.g. `0.12`):
it must be computed at runtime as `miniPlayerHeight / parentHeight`,
because the fraction is relative to the sheet's parent. The `PlayerBar` is
~64–72 px tall inside a `GlassPanel`; measure it (or wrap it in a
fixed-height box) and derive the fraction.

### Code patterns

**Flutter framework — `DraggableScrollableSheet` (`package:flutter/widgets.dart`):**

```dart
// HomeShell body: Stack with tab content underneath, persistent sheet on top.
final _sheetController = DraggableScrollableController();

DraggableScrollableSheet(
  controller: _sheetController,
  initialChildSize: miniFraction, // computed: mini-player height / screen height
  minChildSize: miniFraction,
  maxChildSize: 0.95,
  snap: true,
  snapSizes: [miniFraction, 0.55, 0.95],
  snapAnimationDuration: const Duration(milliseconds: 300),
  builder: (context, scrollController) {
    // MUST pass scrollController to the scrollable child.
    return CustomScrollView(
      controller: scrollController,
      slivers: [
        SliverToBoxAdapter(child: NowPlayingHeader(/* artwork, seek, controls */)),
        SliverList(delegate: SliverChildBuilderDelegate(
          (context, i) => QueueRow(track: queue[i]),
          childCount: queue.length,
        )),
      ],
    );
  },
)
```

**Tap to expand / collapse:**

```dart
// On the mini-player (GestureDetector/InkWell wrapping PlayerBar):
onTap: () => _sheetController.animateTo(
  0.95,
  duration: const Duration(milliseconds: 350),
  curve: Curves.easeOut,
);
// Collapse:
onTap: () => _sheetController.animateTo(
  miniFraction,
  duration: const Duration(milliseconds: 300),
  curve: Curves.easeInOut,
);
// animateTo/jumpTo bypass snap — they land exactly where told.
```

### Gotchas and version-specific notes

- **The #1 gotcha in every source: the `ScrollController` handed to the
  sheet's `builder` must be passed to the scrollable child.** If you ignore
  it, "the sheet will remain at `initialChildSize` and ignore all drag
  attempts." One `CustomScrollView` sharing that controller — header as
  `SliverToBoxAdapter`, queue as `SliverList` — gives one gesture that
  first resizes the sheet, then scrolls the queue once fully expanded. Do
  not nest a separate inner `ListView` with its own controller inside a
  `Column`; that breaks the drag-to-scroll handoff.
- **Snap semantics** (official docs): on finger-lift, if the finger was
  still moving the sheet snaps to the **next** snap size in the direction
  of the drag (fling-aware); if still, to the **nearest**. Snapping applies
  **only to user drags** — programmatic `animateTo`/`jumpTo` bypass snap.
  `snap`/`snapSizes` exist since Flutter 3.3; `snapAnimationDuration`
  since 3.7; `DraggableScrollableController` programmatic control
  stabilised ~3.7. Nothing in the Flutter 3.35 release notes changes this
  widget — no breaking change identified for 3.35.7.
- **Never call `animateTo`/`jumpTo` before the sheet is attached** — guard
  with `isAttached` / a post-frame callback; calling early asserts.
- **Drag handle:** draw a small centred handle (e.g. 36×4 rounded
  container) at the top of the sheet content. (`showDragHandle: true` is
  a `showModalBottomSheet` parameter, not a `DraggableScrollableSheet`
  parameter — do not look for it on the sheet itself.)
- **`expand`:** default `true` (fills parent space). Inside a *modal*
  sheet it must be `false`; for the persistent in-body sheet, leave
  `true`. `shouldCloseOnMinExtent` (drag-to-min dismisses the parent
  sheet) should stay `false` for a persistent player — it is modal-sheet
  behaviour.
- **BottomNavigationBar interplay:** the main unresolved layout question.
  Options: (i) sheet lives in `Scaffold.body`'s `Stack`, so
  `maxChildSize: 1.0` = body height only and the nav bar stays visible
  underneath at full expansion — then fade/slide the `BottomNavigationBar`
  out when the sheet passes ~0.7; or (ii) `Scaffold.bottomSheet:`, which
  the Scaffold docs say triggers a body scrim and FAB scale-down once the
  sheet covers >70% of Scaffold height. Either way, plan to hide/collapse
  the nav bar when expanded. Whether `bottomSheet` sits above or below
  `bottomNavigationBar` in the Scaffold layout order was **not fully
  verified from docs** — test on the A16; the in-body `Stack` alternative
  sidesteps it.
- **Edge-to-edge interaction (item 5):** at `maxChildSize: 1.0` the sheet
  goes under the status bar; use `0.92–0.95` or wrap content in `SafeArea`
  if going to 1.0.
- Rebuilding the sheet with `snap` newly enabled triggers an immediate
  snap unless it has never been dragged since build / last
  `DraggableScrollableActuator.reset` — do not toggle `snap` dynamically.
- `snapSizes` values must lie within `[minChildSize, maxChildSize]`.

### What to integrate into Unbound

- **`lib/main.dart` (`HomeShell`):** replace `Scaffold.bottomNavigationBar:
  Column(children: [PlayerBar, BottomNavigationBar])` with a `Stack` in
  `body`: tab content underneath, `DraggableScrollableSheet` on top. Own
  the `DraggableScrollableController` here (or in the new sheet widget)
  and animate the `BottomNavigationBar` out when the sheet is expanded.
- **`lib/widgets/widgets.dart` (`PlayerBar`, lines 324–429):** becomes the
  sheet's collapsed header. Wrap it in a tap handler that calls
  `animateTo(0.95)`. It stays a `StatelessWidget` fed by
  `track/isPlaying/isStarting/onToggle/onNext/onPrevious`; add no position
  state to it (see item 2). The expanded header (artwork, seek bar,
  transport, queue) is a **new widget** (e.g. `NowPlayingSheet` in the same
  file or a new `lib/widgets/now_playing_sheet.dart`) built around the
  sheet's scroll controller.
- **`lib/services/audio_handler.dart` / `lib/app_state.dart`:** no change
  needed for the sheet itself — the sheet reads the same `PlaybackUiState`
  (queue, currentIndex, isPlaying) that `PlayerBar` already reads. Do **not**
  put sheet-expanded/collapsed state into `PlaybackUiState`; it is local UI
  state owned by `HomeShell`/the sheet widget.

## 2. Seek Scrubbing (Now Playing + notification) + Gapless Transitions

### Recommended approach

**In-app seek:** a `StreamBuilder` on a combined
position/buffered/duration stream, feeding a stateful `SeekBar` that holds
a local drag value and seeks once on release (`onChangeEnd`). Keep position
**out of** `PlaybackUiState` / `AppState.notifyListeners()` — routing 5 Hz
position ticks through the app-wide `ChangeNotifier` would rebuild all five
tabs on every tick. The `StreamBuilder` rebuilds only the seek bar.

**Notification seek:** set `updatePosition: _player.position` (plus
`bufferedPosition: _player.bufferedPosition`) in every `PlaybackState`
broadcast, keep `MediaAction.seek` in `systemActions`, and make sure
`MediaItem.duration` is set. Do **not** push position continuously — the OS
projects it forward from `updatePosition`/`updateTime`/`speed` while
playing. The existing `_emit()`-on-playback-event cadence is correct for
the notification; it just needs the field populated.

**Gapless:** move from one-track-at-a-time `setAudioSource` to a single
playlist via `AudioPlayer.setAudioSources` (the playlist API — see the
deprecation note in "Read this first"), holding the queue and kept in sync
with Unbound's queue, resolving each next track's YouTube URL just before
it is needed — not the whole queue up front.

### Code patterns

**just_audio 0.10.x — official example pattern (`just_audio`, pub.dev
example; `rxdart` for the combine):**

```dart
// Combine the three streams (rxdart — see note below on the dependency).
Stream<PositionData> get _positionDataStream =>
    Rx.combineLatest3<Duration, Duration, Duration?, PositionData>(
        _player.positionStream,
        _player.bufferedPositionStream,
        _player.durationStream,
        (position, bufferedPosition, duration) => PositionData(
            position, bufferedPosition, duration ?? Duration.zero));

// Seek bar rebuilds ONLY itself on each tick — not the whole tree.
StreamBuilder<PositionData>(
  stream: _positionDataStream,
  builder: (context, snapshot) {
    final d = snapshot.data;
    return SeekBar(
      duration: d?.duration ?? Duration.zero,
      position: d?.position ?? Duration.zero,
      bufferedPosition: d?.bufferedPosition ?? Duration.zero,
      onChangeEnd: _player.seek, // seek ONCE, on release
    );
  },
);
```

The example's own comment: "Using StreamBuilder, this widget rebuilds each
time the position, buffered position or duration changes." Play/pause is a
*separate* `StreamBuilder<PlayerState>` on `playerStateStream` that shows a
spinner when `processingState` is `loading`/`buffering`.

**just_audio `SeekBar` drag-value pattern (official example `common.dart`):**

```dart
class _SeekBarState extends State<SeekBar> {
  double? _dragValue;
  // …
  Slider(
    max: widget.duration.inMilliseconds.toDouble(),
    value: _dragValue ?? widget.position.inMilliseconds.toDouble(),
    onChanged: (value) {
      setState(() { _dragValue = value; }); // local only; NO seek yet
      widget.onChanged?.call(Duration(milliseconds: value.round()));
    },
    onChangeEnd: (value) {
      _dragValue = null; // release local override
      widget.onChangeEnd?.call(Duration(milliseconds: value.round()));
    },
  );
}
```

The `_dragValue ?? livePosition` line is the whole trick: while dragging,
the thumb follows the finger and live ticks are ignored; on release the
local value is cleared and the stream resumes driving the thumb. (DM Music
does the same with an explicit `isDragProgress` flag — either form works;
the `_dragValue` form is the just_audio-official one.)

**audio_service 0.18.x — official example pattern (`audio_service` 0.18.17
example + README):**

```dart
// Handler: _transformEvent maps just_audio events -> PlaybackState.
PlaybackState _transformEvent(PlaybackEvent event) => PlaybackState(
      controls: [MediaControl.skipToPrevious, MediaControl.pause,
                 MediaControl.stop, MediaControl.skipToNext],
      systemActions: const {
        MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: /* mapped from _player.processingState */,
      playing: _player.playing,
      updatePosition: _player.position,          // <-- the missing piece in Unbound
      bufferedPosition: _player.bufferedPosition,
    );
// In constructor: _player.playbackEventStream.map(_transformEvent).pipe(playbackState);

// UI: same SeekBar, but driven by audio_service streams:
Stream<MediaState> get _mediaStateStream =>
    Rx.combineLatest2<MediaItem?, Duration, MediaState>(
        _audioHandler.mediaItem,
        AudioService.position, // projected live position
        (mediaItem, position) => MediaState(mediaItem, position));
// … SeekBar(onChangeEnd: (p) => _audioHandler.seek(p))
```

`AudioService.position` is audio_service's own stream of "continuous
changes to the current playback position," projected from the last broadcast
`updatePosition`/`updateTime`/`speed`/`playing` — the UI does not need
just_audio's stream directly if it goes through the handler.

**Gapless — just_audio 0.10.6 playlist API (verified from installed source,
`just_audio.dart:877`):**

```dart
// setAudioSources takes a LIST — this is the playlist API that replaces
// the deprecated ConcatenatingAudioSource (see "Read this first").
Future<Duration?> setAudioSources(
  List<AudioSource> audioSources, {
  bool preload = true,
  int? initialIndex,
  Duration? initialPosition,
  ShuffleOrder? shuffleOrder,
});
await player.setAudioSources(sources, initialIndex: 0);
await player.seekToNext();
await player.seekToPrevious();
await player.seek(Duration.zero, index: 2); // jump to a specific item
```

just_audio docs: "Playback between items will be gapless on Android, iOS
and macOS, while there will be a slight gap on Web." The playlist
prefetches the next item.

**Queue ↔ audio_service mapping (standard pairing):**

```dart
_player.currentIndexStream.listen((i) {
  // -> PlaybackState(queueIndex: i) and mediaItem.add(queue[i])
  // -> keep Unbound's PlaybackUiState.currentIndex in sync here, not by polling
});
Future<void> skipToQueueItem(int i) => _player.seek(Duration.zero, index: i);
```

### Gotchas and version-specific notes

**Position streams (just_audio 0.10.6 — verified from installed source,
`just_audio.dart:693-701, 480, 525`):**

- `positionStream`: "suitable for animating a seek bar… emits more
  frequently on short items… less frequently on long items. The interval
  between each update will be no quicker than once every 16ms and no slower
  than once every 200ms." Implementation:
  `createPositionStream(steps: 800, minPeriod: 16ms, maxPeriod: 200ms)` —
  it aims for 800 updates across the track, clipped to [16ms, 200ms]. For
  a normal-length song that is effectively **~200 ms per tick**. No extra
  throttling is needed at 5 Hz for one small `StreamBuilder`.
- `createPositionStream` docs: "This stream will not emit values while
  audio playback is paused or stalled." A paused player freezes the last
  emitted position — the UI must not assume ticks keep coming while paused
  (it does not need them; the thumb is static then anyway).
- `durationStream` emits `Duration?` — **`null` when unknown**. For a
  YouTube progressive stream the duration normally becomes known shortly
  after load, but until then `duration ?? Duration.zero` makes
  `Slider(max: 0)` **disabled** (Flutter disables a Slider when max ==
  min). Guard: disable/hide the seek bar (show indeterminate progress)
  until `duration != null && duration > Duration.zero`, and clamp every
  seek target into `[0, duration]` and every displayed position with
  `if (position > duration) position = duration` (positions can transiently
  overshoot at track end).
- `bufferedPositionStream`: intermittent updates; buffered position is "the
  position up to which buffered audio is available." A stock `Slider` has
  **no buffered track** — the official `SeekBar` renders buffered as a
  second bar underneath/behind the slider (custom paint or a `Stack` with a
  progress indicator). Budget for a small custom `SeekBar` widget; do not
  expect `Slider` alone to show buffering.

**Rebuild isolation — confirmed as a real problem, with a standard fix:**
routing 5 Hz position ticks through `AppState.notifyListeners()` →
`ListenableBuilder` rebuilding `HomeShell` (all 5 tabs) is a real
performance problem. `notifyListeners()` rebuilds *every* listening
widget's subtree; at 5 Hz that re-runs the `build()` of all five tabs
(cheap for const widgets, expensive for lists/images). The just_audio and
audio_service official examples both use `StreamBuilder` scoped to the seek
bar for exactly this reason. **Fix: do not add position/duration to
`PlaybackUiState` at all.** Expose the streams from the handler (or use
`AudioService.position` + `handler.mediaItem`) and put a
`StreamBuilder<PositionData>` *inside* the Now Playing sheet / seek bar
only. Keep `PlaybackUiState` for low-frequency state (track, playing,
queue, errors) as today.

**Notification seek (audio_service 0.18.19 — verified from installed
source, `audio_service.dart:140-300`):**

- **`PlaybackState` has NO `position` constructor parameter.** The
  constructor takes `updatePosition` (default `Duration.zero`),
  `bufferedPosition`, `speed`, `updateTime`, etc. `position` is a
  **derived getter** ("The current playback position," computed from
  `updatePosition` + `updateTime` + `speed` + `playing`), and `copyWith`
  "unless otherwise replaced, [sets] `updatePosition` … to `position`."
  So the fix is exactly one field: **`updatePosition: _player.position`**
  in `_emit()` (plus `bufferedPosition: _player.bufferedPosition`). The
  diagnosis's "does NOT set `position` or `updatePosition`" should be read
  as "does not set `updatePosition`."
- **Setting `updatePosition` is what makes the notification seek bar
  move.** The docs: "You should not broadcast position changes
  continuously because listeners will be able to project the current
  position after any elapsed time… Instead, only broadcast position updates
  when they are different from expected (e.g. buffering, or seeking)."
  Unbound's existing `_emit()`-on-playback-event cadence is *correct* for
  the notification; it just needs the field populated. **Do not add a
  200 ms `positionStream → playbackState.add(copyWith(updatePosition: …))`
  loop** — that is the one pattern the README explicitly discourages, and
  it would spam the platform channel. (One real-world issue reporter *did*
  do the copyWith-on-positionStream loop; it is a workaround for an
  OxygenOS bug, not the recommended pattern.)
- **What makes the notification seek bar *scrubbable* (not just moving):**
  two things together — (1) `MediaAction.seek` in `systemActions` (Unbound
  already has this), which Android maps to `ACTION_SEEK_TO` ("Adding the
  SEEK_TO action… makes the seekbar position marker draggable. If this is
  not supplied seek will be disabled but progress will still be shown"),
  and (2) **`MediaItem.duration` must be set** — Android: "If duration
  isn't set, such as for live broadcasts, then the progress indicator won't
  be shown on the seekbar." Unbound's `_emit()` **does** set `duration`
  from `track.duration` (verified in the code), so this half is already in
  place — but note `track.duration` is nullable, and for tracks where it
  is null the notification seek bar will not show progress even after
  `updatePosition` is fixed. Prefer just_audio's actual duration (from
  `durationStream`) over the nullable metadata duration when wiring this.
- **Some Android devices will not render the seek bar correctly unless
  the notification icon is a monochrome white icon on a transparent
  background and the notification color is a non-transparent color**
  (audio_service docs on `systemActions`). Unbound's `AudioServiceConfig`
  in `main.dart` sets **neither** `androidNotificationIcon` nor
  `notificationColor` — check this on the A16 when testing notification
  seek; if the seek bar does not render, this is the first suspect.
- **Does the handler need `SeekHandler` to receive notification seeks?
  No — verified from installed source.** The platform dispatches a seek
  straight to the handler's `seek()` override
  (`audio_service.dart:3970-3971`, `(await handlerFuture).seek(request.position)`).
  The `SeekHandler` mixin (`audio_service.dart:3220`) only adds default
  `fastForward`/`rewind`/`seekForward`/`seekBackward` implementations
  (continuous ±10 s seeking at 1 s intervals while held). Unbound's
  existing `seek()` override (audio_handler.dart:540-542) already receives
  notification seeks. Mixing in `SeekHandler` is optional — it buys the
  press-and-hold fast-forward/rewind behaviours, not seek itself. The
  class is currently declared as `class UnboundAudioHandler extends
  BaseAudioHandler` (line 77) — no mixin. Adding `with SeekHandler`
  (and `QueueHandler` if queue ops are exposed) matches every official
  example and costs nothing, but it is not required for seek to work.
  Verify at runtime on the A16: drag the notification seek bar and
  confirm `seek()` fires.
- **Seek guard:** no just_audio documentation states that `seek()` during
  `loading`/`buffering` throws or is forbidden. The guard is UI-level and
  defensive, not API-mandated: disable the slider while `processingState`
  is `loading`/`buffering` or `duration` is null/zero; clamp the target;
  `await` the `seek()` Future and catch `PlayerException` (seek can fail
  on a stale/expired stream URL). Do not invent a "seek-while-loading
  crashes" claim.
- **Seeking into a playlist:** `seek(Duration, index:)` targets a
  specific item; plain `seek(Duration)` seeks within the *current* item.
  After `seekToNext()`/`skipToQueueItem`, position resets — the UI's
  `PositionData` stream follows automatically via `currentIndexStream` /
  `durationStream` changing.

**Gapless (just_audio 0.10.6 / audio_service 0.18.19):**

- Gapless is a property of the playlist API + ExoPlayer on Android: the
  next item is prepared in advance ("prefetch"), so there is no
  re-`setAudioSource` gap. It **does** work with audio_service's
  queue/`MediaItem` model — that is the standard pairing (just_audio owns
  the playlist, audio_service owns the system queue mirror: `queue`,
  `queueIndex`, `skipToQueueItem` → `seek(Duration.zero, index: i)`,
  `currentIndexStream` → `mediaItem`/`queueIndex` updates). No conflict;
  the two queues must just be kept in sync (add/remove/insert on both).
- **Unbound-specific gotcha: YouTube stream URLs are client-tied and
  expire.** A playlist built from URLs resolved for the *whole* queue up
  front will go stale for later tracks. The correct shape is: resolve URLs
  lazily — keep the playlist holding the current track + the next 1–2
  resolved tracks, and append freshly-resolved URLs as the queue advances
  / as radio refills (the existing "refill within 5" logic is the natural
  hook). `useLazyPreparation` (the default) means just_audio prepares each
  child "as late as possible before needed for playback" — but the URL
  still has to *be in* the playlist already, so lazy preparation does not
  by itself solve URL expiry; the *resolution* timing is what matters.
- **Deprecation verified (not just rumoured):** `ConcatenatingAudioSource`
  carries `@Deprecated('Use AudioPlayer.setAudioSources instead')` in the
  installed 0.10.6 source (`just_audio.dart:2921`; changelog line 40).
  `setAudioSources` takes `List<AudioSource>` with `preload`,
  `initialIndex`, `initialPosition`, `shuffleOrder`. It still works in
  0.10.6 (deprecated, not removed), but new code should use
  `setAudioSources`. Also deprecated in the same release:
  `LoopingAudioSource` (use `List.filled(N, source)`).
- Other gapless gotchas: gapless is Android/iOS/macOS only — "a slight gap
  on Web" (irrelevant for the APK); `LoopMode` interacts with the end of a
  playlist (with `LoopMode.off` the player ends at the last item —
  Unbound's `queueEnded`/radio-refill logic must handle
  `ProcessingState.completed` on the *last* item, not per-item);
  `seekToNext()` at the last item is a no-op/error depending on loop mode
  — guard next/previous buttons at the ends when loop is off.
- Preloading alternative (if the playlist refactor is rejected):
  resolving the next track's URL early and calling `setAudioSource` on
  track end still has a gap (load + buffer + the known no-timeout
  `setAudioSource` hazard the project already fixed with a 30 s timeout).
  It is strictly worse than the playlist API and should not be presented
  as equivalent.

### What to integrate into Unbound

- **`lib/services/audio_handler.dart` (`UnboundAudioHandler`):**
  1. Expose position data: add a `Stream<PositionData>` (or expose
     `_player.positionStream` / `bufferedPositionStream` /
     `durationStream` getters, or a combined stream built in the
     handler) — do **not** add position/duration fields to
     `PlaybackUiState`. Note: `rxdart` 0.28.0 is already in `pubspec.lock`
     as a transitive dependency, so the official `Rx.combineLatest3`
     pattern is available — but it should be added as an explicit direct
     dependency in `pubspec.yaml` (or hand-roll the combine with three
     listeners feeding one `StreamController<PositionData>`).
  2. In `_emit()`: add `updatePosition: _player.position` and
     `bufferedPosition: _player.bufferedPosition` to the `PlaybackState`;
     prefer just_audio's actual duration over the nullable
     `track.duration` for `MediaItem.duration` where possible. The
     existing `seek(Duration)` override (lines 540–542) already receives
     notification seeks; optionally declare `with SeekHandler` for the
     press-and-hold behaviours.
  3. Gapless (larger change, do after seek works): replace per-track
     `setAudioSource(singleUri)` with one playlist via
     `setAudioSources(useLazyPreparation: true, children: [resolved URIs
     for current + next 1–2])`; keep it in sync with the Unbound queue
     via add/insert/remove as tracks are queued/dequeued and as radio
     refills; drive `currentIndexStream` → `PlaybackUiState.currentIndex`
     + `mediaItem` + `PlaybackState(queueIndex:)`; implement
     `skipToQueueItem(i) => _player.seek(Duration.zero, index: i)`; keep
     the existing 30 s `setAudioSource` timeout and fresh-URL retry logic,
     now applied at resolve/append time.
- **`lib/widgets/widgets.dart`:** add a stateful `SeekBar` widget (copy
  the *pattern*, not Musify code — the `_dragValue` pattern above, from
  just_audio's own example) with
  `duration/position/bufferedPosition/onChangeEnd`; use it in the new Now
  Playing sheet. Do not put the drag value in `AppState`.
- **`lib/app_state.dart` (`AppState`):** no position/duration fields. It
  keeps subscribing to `PlaybackUiState` for track/playing/queue. The seek
  bar subscribes directly to the handler's position stream via
  `StreamBuilder`, bypassing `AppState` entirely.
- **`lib/main.dart` (`HomeShell`):** no change for seek itself; the
  `StreamBuilder<PositionData>` lives inside the Now Playing sheet widget,
  so position ticks rebuild only the seek bar. For notification seek,
  check `AudioServiceConfig` — `androidNotificationIcon` and
  `notificationColor` are currently unset (see gotcha above).

## 3. High-Res Notification Artwork

### Recommended approach

Two steps, in order:

1. **Resolve the best-available thumbnail in app code and cache it to a
   local file** (e.g. `covers/<id>.jpg` under the app documents dir — new
   work in `DownloadsService` or a small cover-cache helper). Try
   `maxResUrl` → `standardResUrl` → `highResUrl`, checking each with a
   cheap HTTP status check (or download attempt) and falling back on
   failure. Then point `MediaItem.artUri` at the local file with
   `Uri.file(...)`.
2. **Keep the remote `hqdefault` URL as the fallback** `artUri` when no
   local cover file exists yet, so art still appears. Optionally set
   `AudioServiceConfig(artDownscaleWidth: 512, artDownscaleHeight: 512)`
   to bound decoded bitmap memory.

Do **not** just swap `thumb` to `maxResUrl`. The `maxResUrl` getter
synthesises a URL whether or not the image exists, and audio_service has no
fallback chain — a 404 leaves the notification with no art at all.

### How `artUri` actually works in audio_service 0.18.19 (verified from installed source)

**Dart side — `audio_service.dart`, `_observeMediaItem` (~lines 1030–1095)
and `_loadArtwork` (~1242–1262):**

- `artUri == null` or `content://` → the MediaItem is sent straight to the
  platform; no Dart-side fetch.
- `file://` → sent straight, with the file path passed through as the
  `artCacheFile` extra. **No existence check** — a missing file just decodes
  to nothing natively.
- `http(s)://` → audio_service first checks `flutter_cache_manager`'s
  memory cache. On a hit it sends the cached file path immediately. On a
  miss it **sends the MediaItem to the platform first (notification appears
  immediately, without art)**, then downloads via
  `cacheManager.getSingleFile(artUri)` (honouring `MediaItem.artHeaders`,
  added in 0.18.6), then **re-sends** the MediaItem with `artCacheFile`
  pointing at the downloaded file, so the art pops in late. On download
  failure `_loadArtwork` catches the exception, prints `Error loading
  artUri: …`, returns `null`, and the notification simply stays art-less —
  no crash, no retry until the next `mediaItem` emission. There is also an
  `operationId` guard so a stale download (track changed while downloading)
  does not overwrite the new track's art.

**Android side — `AudioService.java`, `loadArtBitmap` (~175–250) and
`setMetadata` (~786–805):**

- Three cases: `content://` via `openFileDescriptor` (or `loadThumbnail`,
  default 192×192, on Android 10+), otherwise
  `BitmapFactory.decodeFile(artUri.getPath())` — i.e. the Dart-side cache
  file or a `file://` path.
- Decoded bitmaps go into an in-memory `LruCache` sized at 1/8 of max heap;
  any exception returns `null` (no art, notification still shows).
- The bitmap is put into the session metadata as
  `METADATA_KEY_ALBUM_ART` / `METADATA_KEY_DISPLAY_ICON` and used as the
  notification large icon (`builder.setLargeIcon(artBitmap)`, ~line 629).
- Downscaling only happens if configured:
  `AudioServiceConfig.artDownscaleWidth` / `artDownscaleHeight` (both or
  neither — there is an assert), default `-1` = full-resolution decode.
  `AudioService.init` also accepts `androidArtDownscaleSize: Size`
  (0.18.19 source, line 1353).

**YouTube thumbnails — `youtube_explode_dart` 3.1.0 `ThumbnailSet`
(verified from installed source, `lib/src/common/thumbnail_set.dart`):**
the getters are pure URL templates built from the video id on
`img.youtube.com` — they do **not** verify availability:

| Getter | URL | Size |
|---|---|---|
| `lowResUrl` | `default.jpg` | 120×90 |
| `mediumResUrl` | `mqdefault.jpg` | 320×180 |
| `highResUrl` | `hqdefault.jpg` | 480×360 |
| `standardResUrl` | `sddefault.jpg` | 640×480, "Not always available" |
| `maxResUrl` | `maxresdefault.jpg` | 1280×720, "Not always available" |

Per Google's thumbnail docs and multiple sources, `maxres` (and
`standard`) exist only for HD uploads / videos with a custom thumbnail;
older or SD-only videos return **404** for `maxresdefault.jpg`, while
`hqdefault` exists on virtually all public videos. The safe order is
maxres → sd → hq → mq. Unbound's `_toTrack`
(`lib/services/youtube_service.dart:62-64`) currently sets `thumb` to
`highResUrl` (480×360) with `mediumResUrl` fallback — that is the current
notification-art resolution.

**What Android displays:** the legacy Android docs state album art in
`MediaMetadataCompat` has a maximum of **320×320dp** and is scaled down if
larger. Chromium's media-notification code uses **512px on high-end devices
/ 256px on low-end** as the ideal media-image size. A commonly cited
recommendation for the notification large icon is 256×256. Practical
conclusion: **512×512 is the sweet spot** — sharp on any current phone,
small in memory (~1 MB as ARGB_8888). A 1280×720 maxres bitmap decodes to
~3.7 MB and is downscaled by the system anyway, so feeding it raw is
wasteful unless `artDownscaleWidth/Height` is set.

### Gotchas and version-specific notes

- **Remote art never blocks the notification** — it appears art-less first,
  art arrives later. A slow URL costs nothing but a late pop-in.
- **No fallback chain:** one `artUri` per MediaItem. If it 404s, you get no
  art — audio_service will not try the next-best URL. Fallback must happen
  in app code before emitting.
- **`file://` must exist at emit time.** If the cover downloads after
  `_emit()`, nothing re-sends the MediaItem — the handler must call
  `_emit()` again once the file lands.
- **No permission / FileProvider needed for `file://` art in the phone
  notification:** audio_service runs in the same app process and reads the
  path directly with `BitmapFactory.decodeFile`. FileProvider would only
  matter for sharing the URI with another app.
- **Android Auto caveat (reported, not verified):** audio_service issue
  #1117 reports `file://` art shows in the phone notification but is empty
  in Android Auto, while a remote URL works there — external clients read
  `METADATA_KEY_DISPLAY_ICON_URI` and cannot read the app's private files.
  For Unbound (personal, phone-only) this is acceptable; just do not expect
  local-file art to appear in a car head unit.
- **`content://` art URIs are supported on Android since 0.18.5** — an
  alternative if covers ever come from MediaStore, not needed here.
- **Queue art is not preloaded by default:** `AudioServiceConfig.preloadArtwork`
  defaults to `false`; queue items' art is only fetched when they become the
  current item. Only the current item's art matters for the notification
  anyway.
- **Lock-screen art:** audio_service's own comment on `setMetadata` notes
  Android 11 removed the lock-screen album-art background; on Android 13+
  the artwork surfaces as the media notification's large icon / media-player
  art in the shade and lock screen. Samsung One UI behaviour on the A16 5G
  was not separately verified.
- **Changelog anchors:** 0.18.0 — single isolate + "Improve artUri
  performance on Android"; 0.18.5 — `content://` art URIs; 0.18.6 —
  `MediaItem.artHeaders`; 0.17.0 — `artUri` type changed from `String` to
  `Uri`.

### What to integrate into Unbound

- **`lib/services/youtube_service.dart` — `_toTrack` (lines 62–64):** keep
  `highResUrl` as the *remote fallback*, but also expose the higher
  candidates. Minimal change: add a `thumbHigh`/`maxThumb` field to
  `Track`, or a helper `bestThumbUrl(Video)` returning the maxres URL
  string — **but only use it after an availability check**, not blindly.
- **`lib/services/downloads_service.dart` (new work — the `artworks/`
  saving does not exist yet):** add e.g. `coverFileFor(Track)` /
  `ensureCover(Track)` that downloads the best-available thumb (try maxres
  → sd → hq, via HTTP status/download attempt) to `<app
  documents>/covers/<id>.jpg` (or `artworks/`, to match the brief's
  intended path — pick one name and use it consistently). Audio downloads
  already live in `downloads/`; covers should be a sibling dir, not mixed
  in.
- **`lib/services/audio_handler.dart` — `_emit()` (lines 159–210):**
  `artUri` selection becomes: local cover file exists →
  `Uri.file(coverFile)`; else remote `track.thumb` (hqdefault) →
  `Uri.parse(...)`; else null. Apply in both the current-item MediaItem
  (~line 176) and the queue MediaItems (~line 204). After a cover finishes
  downloading mid-track, call `_emit()` again so audio_service re-sends
  the MediaItem with the file path.
- **`lib/models/track.dart` — `Track.thumb`:** stays the remote URL (used
  by the in-app `TrackCover` widget too). If a separate high-res URL is
  stored, add a field rather than changing `thumb`'s meaning.
- **`lib/main.dart` — `AudioService.init` config:** optionally add
  `artDownscaleWidth: 512, artDownscaleHeight: 512` to `AudioServiceConfig`
  (or `androidArtDownscaleSize: const Size(512, 512)` on `init`) so a
  1280×720 source is decoded at notification size instead of full
  resolution.

```dart
// Sketch — cover resolution (DownloadsService or a cover helper, NEW code):
// try maxRes -> standard -> high; first HTTP 200 wins; save bytes to
// <docs>/covers/<videoId>.jpg; return the File, or null if all fail.
Future<File?> ensureCover(Track track) async { /* ... */ }

// In _emit():
artUri: coverFile != null
    ? Uri.file(coverFile.path)          // local, instant, full-res
    : (track.thumb.isEmpty ? null : Uri.parse(track.thumb)), // remote hq fallback
```

## 4. Audio Becoming Noisy Handler

### Recommended approach

Add an explicit `becomingNoisyEventStream` listener in the
`UnboundAudioHandler` constructor, next to the existing interruption
listener, and have it call **the handler's own `pause()`** (the
`audio_service` override) — not `_player.pause()` directly. Keep
just_audio's `handleInterruptions: true` (the current default). No manifest
change, no broadcast receiver in app code.

### Verified behaviour

**`audio_session` 0.2.4 — becoming-noisy is a separate stream, not part of
interruptions** (verified from installed source,
`lib/src/core.dart:186-187`, `lib/src/android.dart:65-66`):

```dart
// audio_session — Stream<void>, payload is always null; there is no
// event object to inspect, unlike interruptionEventStream.
Stream<void> get becomingNoisyEventStream =>
    _becomingNoisyEventSubject.stream;
```

- `interruptionEventStream` → `Stream<AudioInterruptionEvent>` with `begin`
  (bool) and `type` (`AudioInterruptionType.duck` / `.pause` / `.unknown`).
- `becomingNoisyEventStream` → `Stream<void>`. It fires for wired-headphone
  unplug **and** Bluetooth disconnect (anything where output falls back to
  the speaker). You distinguish it trivially: it is a different stream with
  no event payload — there is no `type`/`begin` to check.

**Native Android path (verified, `AndroidAudioManager.kt`):** on audio-focus
grant, audio_session dynamically registers a `BroadcastReceiver` for
`AudioManager.ACTION_AUDIO_BECOMING_NOISY` (`registerNoisyReceiver()`,
~line 654; called at ~line 367) and unregisters it when focus is abandoned
(~line 375). It uses `ContextCompat.registerReceiver(...,
RECEIVER_EXPORTED)`. **No manifest declaration is needed or wanted** —
Android 8+ restricts manifest-registered implicit broadcasts, and the
Android docs' own pattern is register-on-play / unregister-on-stop, which
audio_session already does internally when just_audio activates the session
on `play()`.

**`just_audio` 0.10.6 built-in behaviour (verified from installed source,
`just_audio.dart:370-410`):** with `handleInterruptions: true` (default),
the `AudioPlayer` constructor subscribes to both streams:

```dart
// just_audio — AudioPlayer constructor, handleInterruptions: true
session.becomingNoisyEventStream.listen((_) {
  pause();            // pause only — nothing arms a resume
});
session.interruptionEventStream.listen((event) {
  if (event.begin) {
    switch (event.type) {
      case AudioInterruptionType.duck:
        // halve volume (game usage only); _playInterrupted = false;
      case AudioInterruptionType.pause:
      case AudioInterruptionType.unknown:
        if (playing) { pause(); _playInterrupted = true; }
    }
  } else {
    switch (event.type) {
      case AudioInterruptionType.duck:   // restore volume
      case AudioInterruptionType.pause:
        if (_playInterrupted) play();
        _playInterrupted = false;
      case AudioInterruptionType.unknown:
        _playInterrupted = false;        // <-- NO resume
    }
  }
});
```

So the earlier understanding is **confirmed exactly**:
- becoming-noisy → `pause()`, no resume is ever armed.
- interruption begin (`pause` or `unknown`) → pause + `_playInterrupted =
  true` (only if actually playing).
- interruption end → resume **only** for `pause`-type (`if
  (_playInterrupted) play()`); for `unknown`-type it just clears the flag
  and stays paused. That is the gap Unbound's explicit listener already
  closes.

One more critical detail from the same source: **`AudioPlayer.pause()`
itself sets `_playInterrupted = false`** (just_audio.dart ~line 1131), and
`play()` also clears it. So any explicit pause clears just_audio's internal
resume flag — just_audio can never surprise-resume after a becoming-noisy
pause. The danger is only Unbound's *own* explicit interruption listener,
which bypasses that flag (see below).

**Official usage pattern** (audio_session README / example
`example/lib/main.dart`):

```dart
// audio_session — official example (with handleInterruptions: false in
// the demo so it can show manual handling; Unbound keeps the default true)
audioSession.becomingNoisyEventStream.listen((_) {
  debugPrint('PAUSE');
  _player.pause();
});
```

### The `_wantsPlaying` decision — this is the crux

**Set `_wantsPlaying = false` on becoming-noisy. Do not keep it `true`.**
Concretely, route through the handler's own `pause()` override
(`audio_handler.dart:491-497`), which already does `_wantsPlaying = false;
_emit(); await _player.pause();`.

Consequences of each choice:

| | `_wantsPlaying = false` (recommended — call handler `pause()`) | Keep `_wantsPlaying = true` (pause `_player` only) |
|---|---|---|
| Play/pause button | Correct: `isStarting` (`wantsPlaying && !isPlaying`) is false, button shows Paused | **Wrong:** button shows "Starting…" forever, since the player will never confirm playing |
| Notification | Correct: `_emit()` swaps the control to play | **Wrong:** notification keeps showing the pause button for a paused player |
| Interruption-resume logic | Safe: the constructor's listener (`!event.begin && _wantsPlaying && !_isPlaying → play()`) cannot fire | **Unsafe — the trap:** becoming-noisy emits *no* interruption event, so nothing resumes immediately — but the *next* interruption-end event (e.g. a navigation-prompt duck ending, a call ending) sees `_wantsPlaying == true` and `!_isPlaying` and calls `play()`, resuming **through the phone speaker** after the user unplugged their headphones. That is exactly the outcome becoming-noisy exists to prevent, and Unbound's explicit listener (which was added to close the `unknown`-type gap) is what would cause it, because it does not consult just_audio's `_playInterrupted` flag. |

So the two listeners must share one invariant: **`_wantsPlaying` means "the
user still wants sound right now"**. Becoming-noisy means they don't (until
they press play again), so it clears the flag — same as a user pressing
pause. Interruption-end resumes only when the flag survived the
interruption, which is precisely the duck/`pause`-type case.

Real-world corroboration (mechanism reference only): Linthra, a
just_audio/audio_service app, hit the same self-resume bug and fixed it by
classifying transient vs permanent focus loss and clearing resume state on
becoming-noisy (PR #175, audio-bluetooth-cpu-audit doc).

### Gotchas

- **Double pause is harmless.** just_audio's own becoming-noisy listener
  (default `handleInterruptions: true`) already pauses the player; the
  explicit listener adds the `_wantsPlaying = false` + `_emit()` state fix.
  Both call `pause()`; the second is a no-op if already paused.
- **Do NOT set `handleInterruptions: false`** to "take over" — that disables
  just_audio's duck/`pause`/`unknown` handling too, and you would have to
  reimplement all of it (including volume ducking). Keep the default; the
  explicit listener is additive state-keeping, not a replacement.
- **Register once, in the constructor**, in the same
  `AudioSession.instance.then(...)` block as the existing interruption
  listener (audio_handler.dart:88–99). The handler is never disposed in this
  app, so matching the existing fire-and-forget subscription style is fine;
  if a dispose path is ever added, cancel both subscriptions there.
- **Unplugged while buffering/starting** (`_wantsPlaying == true`,
  `_isPlaying == false`): handler `pause()` clears the flag and pauses the
  player — this matches the existing tap-while-Starting cancel behaviour in
  `togglePlay()`.
- **Unplugged while already paused:** `_wantsPlaying` is already false;
  `pause()` is a no-op. No edge case.
- **No resume-on-reconnect:** nothing in either package listens for a
  Bluetooth *connect* to start playback, and the explicit listener must not
  add one. Resume is always an explicit user press (or a notification /
  media-button `play()`).

### What to integrate into Unbound

- **`lib/services/audio_handler.dart` — constructor (lines 88–99):** add the
  becoming-noisy subscription inside the existing
  `AudioSession.instance.then(...)` block, alongside the interruption
  listener. One small addition, no new file:

```dart
// audio_session — explicit becoming-noisy handler (NEW, in the
// UnboundAudioHandler constructor, next to the interruption listener).
unawaited(AudioSession.instance.then((session) {
  // Headphones unplugged / Bluetooth disconnected: pause and STAY paused.
  // Must go through pause() (not _player.pause()) so _wantsPlaying is
  // cleared — otherwise the interruption-end listener below would resume
  // through the phone speaker on the next focus regain.
  session.becomingNoisyEventStream.listen((_) {
    unawaited(pause());
  });
  session.interruptionEventStream.listen((event) {
    if (!event.begin && _wantsPlaying && !_isPlaying) {
      unawaited(play());
    }
  });
}));
```

- **`lib/services/audio_handler.dart` — `pause()` (lines 491–497):** no
  change needed — it already sets `_wantsPlaying = false`, calls `_emit()`
  (button + notification flip to play), then pauses the player. This is why
  routing through it is the whole fix.
- **`lib/main.dart` — `AudioSessionConfiguration.music()` (line 39):** no
  change. The `music` configuration already requests the right
  focus/attributes; becoming-noisy delivery does not depend on a different
  configuration.
- **No manifest change:** audio_session registers/unregisters the
  `ACTION_AUDIO_BECOMING_NOISY` receiver dynamically on focus
  grant/abandon. Verify on-device by unplugging/disconnecting mid-track and
  confirming: audio stops, button shows Paused (not "Starting…"), and a
  subsequent notification-sound/call ending does **not** restart playback.

## 5. Edge-to-Edge Safe Areas

### Recommended approach

**Unbound is almost certainly already edge-to-edge, silently.** Since
Flutter 3.27, apps targeting Android 15 (API 35) automatically opt into
edge-to-edge, and Flutter's default `targetSdkVersion` has been 35 since
3.27. Unbound on Flutter 3.35.7 therefore already draws behind the status
bar and navigation bar on Android 15 — the missing work is not *enabling*
it, it is *handling the insets deliberately* instead of relying on
accident:

1. **Declare it explicitly** in `main()` —
   `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)` before
   `runApp()` — so the behaviour is intentional, identical on pre-15
   devices, and survives a future targetSdk bump.
2. **Keep the Scaffold's default `extendBody: false`.** The body then ends
   above the bottom bar; only the bottom bar itself needs the system inset.
   Do **not** set `extendBody: true` unless the design wants content
   scrolling behind a translucent mini-player — that is a different, harder
   layout.
3. **One inset owner per edge, never two.** Body `SafeArea`: `top: true,
   bottom: false`. The bottom inset is already owned by the stock
   `BottomNavigationBar` (see the verification below) — do **not** wrap the
   bottom column in another `SafeArea(bottom: true)` or it double-pads.
4. **Paint the background behind the bars in Flutter, not with bar
   colours.** On Android 15 the bars are transparent; the app's own
   `#050505` scaffold background is what shows through. `statusBarColor` /
   `systemNavigationBarColor` no longer colour the bars in gesture
   navigation (see gotchas).
5. **Set icon brightness declaratively** with an
   `AnnotatedRegion<SystemUiOverlayStyle>` around the Scaffold (Unbound has
   no `AppBar`, so `AppBar.systemOverlayStyle` does not apply), using
   `SystemUiOverlayStyle.light` (light icons, for a dark background).

### Code patterns

**Enable edge-to-edge — `package:flutter/services.dart`, `SystemChrome` /
`SystemUiMode`:**

```dart
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const UnboundApp());
}
```

What it does (per `api.flutter.dev` `setEnabledSystemUIMode`): specifies
the `SystemUiMode` to have visible while the app runs. `edgeToEdge` = app
draws behind status and navigation bars, bars stay visible as transparent
overlays. The same API page states: *"If your app targets Android SDK 15
(API 35), then your Flutter app uses SystemUiMode.edgeToEdge by default on
Android and setting any of the other SystemUiModes will NOT work"* unless
the opt-out migration is done; on API 36+ there is no opt-out at all. The
Flutter breaking-change doc confirms: *"If your app explicitly sets
`SystemUiMode.edgeToEdge` … then your app is already migrated."*

**Dark-theme overlay style — `package:flutter/services.dart`,
`SystemUiOverlayStyle`:**

```dart
// lib/theme/unbound_theme.dart
static const systemUiOverlayStyle = SystemUiOverlayStyle.light.copyWith(
  statusBarColor: Colors.transparent,              // no effect on Android 15; harmless, helps <15
  statusBarIconBrightness: Brightness.light,       // Android: white icons
  statusBarBrightness: Brightness.dark,            // iOS: light icons (inverted naming)
  systemNavigationBarColor: Colors.transparent,    // no effect in gesture nav on Android 15
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarContrastEnforced: false,
);
```

`SystemUiOverlayStyle.light` = *"System overlays should be drawn with a
light color. Intended for applications with a dark background"*; `.dark` is
the reverse (dark overlays, light background) — the naming is a known
confusion trap. `copyWith` with exactly these fields is verified on the API
class page.

**Declarative placement — `package:flutter/widgets.dart`,
`AnnotatedRegion`:**

```dart
// main.dart — wrap the HomeShell Scaffold (no AppBar exists, so this is the right place,
// not AppBar.systemOverlayStyle)
AnnotatedRegion<SystemUiOverlayStyle>(
  value: UnboundTheme.systemUiOverlayStyle,
  child: Scaffold(/* ... */),
)
```

Prefer this over imperative `SystemChrome.setSystemUIOverlayStyle()` in
`main()`: the imperative call runs once and can be overwritten by a
theme/AppBar rebuild, while `AnnotatedRegion` re-applies for as long as the
widget is visible.

**Body + bottom bar, one inset owner per edge — `package:flutter/widgets.dart`,
`SafeArea`; `package:flutter/material.dart`, `Scaffold`:**

```dart
Scaffold(
  extendBody: false, // default — body stops above bottomNavigationBar
  body: SafeArea(
    top: true,
    bottom: false, // <-- CHANGE from current default (all true): the Scaffold
                    // already reserves the bottom bar's height; a bottom SafeArea
                    // here adds a dead gap above the mini-player.
    child: tabBody,
  ),
  bottomNavigationBar: Column(
    mainAxisSize: MainAxisSize.min,
    // NO SafeArea(bottom: true) here — the stock BottomNavigationBar below
    // already adds the bottom system inset itself (verified, see below).
    children: [PlayerBar(), BottomNavigationBar(/* ... */)],
  ),
)
```

Alternative to a `SafeArea` on the bottom bar, if the stock widget ever
stops self-padding (use one, never both):

```dart
final bottomInset = MediaQuery.paddingOf(context).bottom; // package:flutter/widgets.dart
Padding(padding: EdgeInsets.only(bottom: bottomInset), child: Column(/* ... */))
```

Prefer the granular `MediaQuery.paddingOf(context)` / `viewPaddingOf` /
`viewInsetsOf` accessors over `MediaQuery.of(context)`: the latter rebuilds
on *every* metric change (keyboard, rotation, brightness).

**The three `MediaQuery` paddings — do not conflate them:**

| Property | Meaning |
|---|---|
| `MediaQuery.padding` / `paddingOf` | System intrusions (status bar, nav bar, notch) **minus what an ancestor `SafeArea` already consumed**. This is what `SafeArea` reads internally. Inside a `SafeArea` child it reads as zero on the consumed edges. |
| `MediaQuery.viewPadding` / `viewPaddingOf` | Raw system intrusions, unchanged by `SafeArea` or keyboard. Use when you need the true value *inside* a `SafeArea`. |
| `MediaQuery.viewInsets` / `viewInsetsOf` | Fully-obscured area, in practice the keyboard height (`viewInsets.bottom`). `SafeArea` does **not** consume this. `Scaffold.resizeToAvoidBottomInset` (default `true`) already resizes the body for it. |

### Gotchas and version-specific notes

- **Already enforced, opt-out is temporary and dying.** Android 15
  behaviour-changes doc: *"Apps are edge-to-edge by default on devices
  running Android 15 if the app is targeting Android 15 (API 35)."* The
  Flutter breaking-change doc (landed 3.26.0-0.0.pre, stable 3.27):
  targeting `flutter.targetSdkVersion` opts the app in automatically from
  Flutter 3.27. The only opt-out is the
  `android:windowOptOutEdgeToEdgeEnforcement=true` style attribute in
  `android/app/src/main/res/values/styles.xml` (+ `values-night`), and it
  works **only** on Android 15 / target 35. On Android 16 (API 36) it is
  deprecated/disabled and using it can crash — do not use it; migrate
  instead. Google Play now requires targeting API 36 for new apps/updates
  (per secondary sources), so edge-to-edge is effectively permanent.
  Unbound's manifest declares no opt-out — good.
- **What breaks if insets are ignored:** content draws behind the
  transparent status bar (top of Home / Now Playing hidden under
  clock/icons) and behind the gesture pill / 3-button bar (bottom tab
  labels, mini-player controls unreachable or visually clipped). Also
  `Configuration.screenWidthDp/screenHeightDp` no longer exclude system
  bars for target-35 apps, and non-floating windows are forced to
  `LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS`.
- **Bar colours are dead on Android 15 — do not rely on them:**
  - Gesture nav bar: transparent by default; `setNavigationBarColor` /
    `navigationBarColor` deprecated and **no effect**;
    `setNavigationBarContrastEnforced` also **no effect**.
  - 3-button nav: 80% opaque by default; `setNavigationBarColor` deprecated
    but **still affects** 3-button nav; `setNavigationBarContrastEnforced`
    defaults `true` (adds the 80% scrim).
  - Status bar: transparent by default; `setStatusBarColor` deprecated and
    **no effect** on Android 15; `setStatusBarContrastEnforced` deprecated
    but still has an effect.
  - Consequence for Unbound: the *only* reliable way to colour the area
    behind the bars is the Flutter background (`Scaffold.backgroundColor` /
    theme `#050505` extending to the screen edge). The mini-player + tab
    bar must themselves be **opaque** (solid `#050505`/surface colour),
    otherwise list content scrolling underneath shows through the
    transparent gesture bar.
- **Gesture vs 3-button:** the same `MediaQuery.padding.bottom` /
  `SafeArea(bottom: true)` code adapts automatically — gesture nav reports
  a small bottom inset (pill height), 3-button a larger one. Never
  hard-code a bottom inset height (e.g. 16/24 dp). Test **both** modes on
  the A16 (Settings → Display → Navigation bar).
- **Scaffold semantics (verified from the `Scaffold` API doc):** *"The
  scaffold's `body` is not inset by [MediaQueryData.padding] … although an
  `appBar` or `bottomNavigationBar` will typically cause the body to avoid
  the padding. The `SafeArea` widget can be used within the scaffold's body
  to avoid areas like display notches."* And `extendBody`: *"If true …
  then the `body` extends to the bottom of the Scaffold, instead of only
  extending to the top of the `bottomNavigationBar`"*;
  `extendBodyBehindAppBar` is the top equivalent. So: `extendBody: false`
  (default) is correct for Unbound's opaque bottom chrome; `extendBody:
  true` is only for a floating/translucent bar, and then the body needs its
  own bottom padding equal to bar height + system inset (e.g.
  `SliverSafeArea` for slivers, which do not self-pad — a plain `ListView`
  self-pads from `MediaQuery.padding`, a `CustomScrollView` does not).
- **BottomNavigationBar self-padding — VERIFIED from Flutter SDK source
  (resolves the open question).** `bottom_navigation_bar.dart:1106` in
  Flutter 3.35.7: `final double additionalBottomPadding =
  MediaQuery.viewPaddingOf(context).bottom;` — the stock widget reads the
  **raw** view padding and adds it to its own height (`minHeight:
  kBottomNavigationBarHeight + additionalBottomPadding`) and its content
  padding (`Padding(bottom: additionalBottomPadding)`). Because it reads
  `viewPadding` (raw, unaffected by ancestor `SafeArea`s), it adds the full
  inset **even if an ancestor SafeArea already consumed it** — so wrapping
  Unbound's bottom column in `SafeArea(bottom: true)` **would double-pad**.
  The correct integration is therefore: no `SafeArea` on the bottom column;
  the stock `BottomNavigationBar` owns the bottom inset, and the `PlayerBar`
  sits above it so it needs no bottom inset of its own. Verify on-device:
  if the tab bar sits too high with a dead gap, an inset is being applied
  twice — remove one owner; if icons sit under the gesture pill, none is
  being applied.
- **Samsung / A16:** One UI's gesture bar and 3-button bar follow the same
  Android 15 rules; Samsung adds its own navigation settings but no
  separate inset API. The A16's punch-hole camera is a top `viewPadding`
  inset — the body's `SafeArea(top: true)` already covers it. Which One UI
  / Android version is currently on Daniel's A16 was **not verified** (it
  shipped on Android 14 / One UI 6.1; the Android 15 / One UI 7 update is
  rolling out by region/carrier) — if his phone is still on Android 14, the
  explicit `SystemUiMode.edgeToEdge` call is what makes behaviour
  identical; the `SafeArea` handling is correct on both.
- **Flutter 3.35.7 specifics:** no edge-to-edge or inset API change was
  found in the 3.35 release notes — the edge-to-edge default landed in
  3.27, so 3.35.7 inherits it unchanged.

### What to integrate into Unbound

- **`lib/main.dart` — `main()`:** after
  `WidgetsFlutterBinding.ensureInitialized()`, add
  `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);` (import
  `package:flutter/services.dart`) before `runApp()`. This is the single
  explicit opt-in; it also covers pre-Android-15 devices.
- **`lib/main.dart` — HomeShell `Scaffold`:** wrap the `Scaffold` in
  `AnnotatedRegion<SystemUiOverlayStyle>(value:
  UnboundTheme.systemUiOverlayStyle, …)`. Change the existing body
  `SafeArea` (main.dart:111) to `SafeArea(top: true, bottom: false, …)`.
  Do **not** wrap the `bottomNavigationBar` `Column` (PlayerBar +
  `BottomNavigationBar`) in a `SafeArea` — the stock `BottomNavigationBar`
  already adds the bottom inset itself (verified above). Leave `extendBody`
  at its default `false`; do not add `extendBodyBehindAppBar`.
- **`lib/theme/unbound_theme.dart` — `UnboundTheme`:** add a `static const
  SystemUiOverlayStyle systemUiOverlayStyle =
  SystemUiOverlayStyle.light.copyWith(…)` as in the snippet above
  (transparent colours, `Brightness.light` icons for both bars,
  `systemNavigationBarContrastEnforced: false`). Keep
  `ThemeData.brightness == Brightness.dark` — a light theme would fight the
  icon brightness.
- **`lib/widgets/widgets.dart` — `PlayerBar`:** no inset code needed inside
  `PlayerBar` itself once the layout is as above; just confirm its
  container/background is opaque (solid surface colour, not transparent) so
  content behind the transparent gesture bar does not bleed through. Same
  for the `BottomNavigationBar` background.
- **Verification (on the A16, both nav modes):** Home top content clear of
  the status bar; mini-player controls and all 5 tab labels/icons fully
  above the gesture pill in gesture mode and above the 3-button bar in
  3-button mode; no dead gap between the tab bar and the screen edge
  (double padding) and no gap between body content and the mini-player
  (body `SafeArea(bottom: false)` fix); rotate to landscape (side
  cutout/gesture insets) as a sanity check.

## 6. Native Haptics

### Recommended approach

Use **only Flutter's built-in `HapticFeedback`**
(`package:flutter/services.dart`) — no new pub dependency. It is
deliberately terse ("calls default platform behaviour", "not suitable for
precise control"), which is exactly right for Unbound: subtle confirmation
ticks, not custom vibration patterns. Recommended mapping for a music
player:

| Unbound moment | Call | Why |
|---|---|---|
| Play / pause tap, skip next/previous, tab change, like/favourite tap | `HapticFeedback.lightImpact()` | Lightest confirmation; the default tap feel |
| Seek-scrub **start** (thumb grab) | `HapticFeedback.mediumImpact()` | Marks the mode change into scrubbing |
| Seek-scrub **detents** while dragging (crossing each 1 s / 5 s / 10% mark) | `HapticFeedback.selectionClick()` | Discrete-step tick; see throttling below |
| Seek-scrub **release** (seek commits) | `HapticFeedback.lightImpact()` | Confirms the drop |
| Long-press (e.g. long-press a track for options) | `HapticFeedback.mediumImpact()` — or `vibrate()` only if a deliberately stronger buzz is wanted | `vibrate()` maps to `LONG_PRESS`; it is noticeably stronger and easy to overuse |
| Action completed (added to liked / queue updated) | `HapticFeedback.successNotification()` | Only if a success tick is wanted; API 30+ on Android (A16 qualifies) |
| Errors | Avoid `heavyImpact()` / error haptics in normal playback | `heavyImpact` is the strongest impact; reserve for genuinely destructive/failed actions, if ever |

Do **not** use the `vibration` / `haptic_feedback` / `vibration_flutter`
packages: they exist for custom durations, amplitudes and waveforms, which
Unbound does not need, and they add a manifest permission and a dependency
for no benefit here. Fire haptics fire-and-forget (do not `await` them in a
tap handler — they return `Future<void>` and awaiting would delay the UI
action).

### Code patterns

**All methods are static on `HapticFeedback`,
`package:flutter/services.dart`; verified Android mappings from
`api.flutter.dev` and the Flutter SDK source
(`haptic_feedback.dart`):**

| Method | Android mapping (verified) | iOS mapping (verified) |
|---|---|---|
| `lightImpact()` | `HapticFeedbackConstants.VIRTUAL_KEY` | `UIImpactFeedbackGenerator`, style Light |
| `mediumImpact()` | `HapticFeedbackConstants.KEYBOARD_TAP` | `UIImpactFeedbackGenerator`, style Medium |
| `heavyImpact()` | `HapticFeedbackConstants.CONTEXT_CLICK`, API 23+; no effect below API 23 | `UIImpactFeedbackGenerator`, style Heavy |
| `selectionClick()` | `HapticFeedbackConstants.CLOCK_TICK` | `UISelectionFeedbackGenerator` (iOS 10+) |
| `vibrate()` | platform API simulating long press, `HapticFeedbackConstants.LONG_PRESS` | default system vibration (`kSystemSoundID_Vibrate`) |
| `successNotification()` | `HapticFeedbackConstants.CONFIRM`, API 30+; no effect below API 30 | `UINotificationFeedbackGenerator`, type Success |
| `warningNotification()` / `errorNotification()` | **Not verified** — API pages not opened; do not assert a mapping | `UINotificationFeedbackGenerator` warning/error (per class doc) |

**Tap feedback — `PlayerBar` buttons (`lib/widgets/widgets.dart`):**

```dart
import 'package:flutter/services.dart';

IconButton(
  icon: const Icon(Icons.play_arrow),
  onPressed: () {
    HapticFeedback.lightImpact(); // fire-and-forget; do not await
    audioHandler.play();          // or togglePlay() — haptic first, action second
  },
)
```

Same one-liner on pause, skip-previous/next, and (if wanted) the tab
`onTap` in the HomeShell `BottomNavigationBar`. Note: `BottomNavigationBar`
has an `enableFeedback` property ("Whether detected gestures should provide
acoustic and/or haptic feedback") — its default was **not verified**, so
check on-device whether taps already tick; if they do, do **not** add a
manual call on the same tap or it will double-fire.

**Scrub haptics with detents — future seek slider (Now Playing sheet /
`PlayerBar`):**

```dart
// State held in the slider's widget: last detent crossed + throttle timestamp.
double _lastHapticSecond = -1;

Slider(
  value: position.inSeconds.toDouble(),
  max: duration.inSeconds.toDouble(),
  onChangeStart: (_) => HapticFeedback.mediumImpact(),
  onChanged: (v) {
    // Fire ONLY when crossing a whole-second (or 5-second) boundary —
    // never on every onChanged tick. onChanged fires continuously while dragging.
    final second = v.floorToDouble();
    if (second != _lastHapticSecond) {
      _lastHapticSecond = second;
      HapticFeedback.selectionClick();
    }
    // update the UI position here; do NOT seek the player until onChangeEnd.
  },
  onChangeEnd: (v) {
    HapticFeedback.lightImpact();
    audioHandler.seek(Duration(seconds: v.toInt()));
  },
)
```

This detent pattern is the one Flutter itself uses: in the
`CupertinoSlider` haptics PR (#167362, merged for Flutter 3.35), feedback
fires only when the index changes (`hasSuitableHapticHardware && index !=
_lastHapticIndex`), with `selectionClick()` on a slow drag and
`mediumImpact()` on a fast drag. The `tactile_fluid_slider` package
documents the same idea as "magnetic haptic detents" firing
`selectionClick()` only at thresholds (25/50/75/100%). For a seek bar, a
1-second detent is a reasonable starting point; a 5-second detent feels
calmer on long tracks — tune by feel on the A16, and consider a time
throttle as well (e.g. ignore ticks < ~50–100 ms apart) if fast scrubbing
still buzzes.

**Manifest (belt-and-braces) — `android/app/src/main/AndroidManifest.xml`:**

```xml
<uses-permission android:name="android.permission.VIBRATE"/>
```

See permission discussion below — this one line is cheap insurance.

### Gotchas and version-specific notes

- **Permission — verified, not just recommended.** `VIBRATE` is a *normal*
  permission (install-time granted, no runtime prompt, no user-facing
  permission dialog). Verified against the installed sources: it is **not**
  in the Flutter engine's `AndroidManifest.xml` and **not** in Unbound's
  `AndroidManifest.xml` (checked — the manifest has INTERNET, WAKE_LOCK,
  FOREGROUND_SERVICE, FOREGROUND_SERVICE_MEDIA_PLAYBACK,
  POST_NOTIFICATIONS, plus the AudioService foreground service and
  MediaButtonReceiver). The mechanism explains the split in secondary
  sources: the impact/selection calls go through
  `View.performHapticFeedback()` (system touch-feedback path, no `VIBRATE`
  needed), while `vibrate()` goes through the `Vibrator` service (which
  does require it). Add the one line to Unbound's own
  `AndroidManifest.xml` regardless — it is auto-granted, costs nothing,
  and removes the question for `vibrate()` and for any future
  `Vibrator`-based code. Verify it appears in the merged manifest after
  the next build.
- **System setting off = silent no-op (by design, not a bug).**
  `HapticFeedback` goes through the platform path, which respects the
  user's touch-feedback setting: if the user turned haptics off, nothing
  plays and the call returns normally — never show an error, never retry,
  never work around it. On stock Android: Settings → Accessibility →
  Vibration & haptics → "Use vibration & haptics" → Touch feedback. On
  Samsung (One UI 7, A16): Settings → Sounds and vibration → System
  vibration → touch-interactions toggle, plus Settings → Sounds and
  vibration → Vibration intensity → touch-interaction slider. Samsung also
  ties its own One UI slider haptics to that same touch-interactions
  switch. If Daniel reports "haptics don't work", the first check is that
  toggle/intensity, not the code.
- **Samsung / A16 motor reality:** the A16 5G is a budget device; its
  vibrator hardware was **not verified** (likely a basic
  eccentric-rotating-mass motor, not a linear resonant actuator). Practical
  consequence: `lightImpact` vs `mediumImpact` may feel much closer together
  than on a flagship, and `selectionClick` ticks may feel mushy. Choose the
  mapping above, then tune by feel on the actual phone — if light and
  medium are indistinguishable, it is the motor, not a code error.
  Samsung's per-category vibration-intensity sliders also scale the feel
  independently of the app.
- **Emulators are silent.** Haptics do not fire on the Android emulator (or
  iOS simulator); calls are safe no-ops there. Always test haptics on the
  physical A16.
- **Safe no-ops elsewhere:** on devices without a vibrator, on unsupported
  API levels (`heavyImpact` < API 23, `successNotification` < API 30 —
  both irrelevant on the A16, which is API 35-class), and on web/desktop,
  the calls simply do nothing. No capability check is needed before calling
  them; `HapticFeedback` has no `canVibrate()` — that exists only in
  third-party plugins.
- **Throttling is mandatory for scrubbing, optional elsewhere.**
  `Slider.onChanged` fires continuously (dozens of times per second during
  a drag). Firing `selectionClick()` per tick produces a continuous buzz,
  masks the detent feel, and wastes battery. Fire only on detent crossings
  (snippet above) and once each on grab/release. Single taps need no
  throttling — a human cannot tap fast enough for it to matter — but do not
  fire a haptic inside a `StreamBuilder` position update or any per-frame
  callback; the position stream ticks ~200 ms and would buzz constantly.
- **Flutter 3.35 specifics:** the 3.35 release notes record haptic feedback
  added to Cupertino interactive widgets — `CupertinoPicker` (#170641) and
  `CupertinoSlider` (#167362). That matters in two ways: (1) it is the
  *Cupertino* widgets that gained built-in haptics; Unbound's **Material**
  `Slider` / `IconButton` / `BottomNavigationBar` do **not** auto-fire
  haptics, so manual calls are still required; (2) the `CupertinoSlider` PR
  is the best in-tree reference for the detent/throttle pattern above. No
  change to the `HapticFeedback` API itself was found in 3.35.
- **Do not fight the platform:** `HapticFeedback` is intentionally terse —
  no duration, amplitude or pattern parameters. If a future design wants a
  custom pattern (e.g. a double-tick on track change), that is the point to
  evaluate the `vibration` package (which needs the `VIBRATE` permission
  and `VibrationEffect` on API 26+), not now.

### What to integrate into Unbound

- **`lib/widgets/widgets.dart` — `PlayerBar`:** add `import
  'package:flutter/services.dart';` and a `HapticFeedback.lightImpact();`
  as the first line of the `onPressed` handlers for play/pause,
  skip-previous, skip-next (and any favourite/like button in the
  mini-player). Keep the call fire-and-forget (no `await`). No new
  dependency, no manifest change strictly required for these calls — but
  see below.
- **`lib/widgets/widgets.dart` / future Now Playing sheet — seek slider
  (Items 1+2 build):** implement the detent snippet above in the slider's
  `onChangeStart` / `onChanged` / `onChangeEnd`: `mediumImpact()` on grab,
  `selectionClick()` only when crossing a whole-second (start with 1 s,
  tune to 5 s if it feels busy), `lightImpact()` + `audioHandler.seek(…)`
  on release. **Do not** seek the player inside `onChanged` and do not fire
  a haptic from the position `StreamBuilder` — that path updates
  continuously and would buzz. The seek itself already exists as
  `seek(Duration)` in the audio layer; the haptics wrap the gesture, they
  do not change the seek logic.
- **`lib/main.dart` — HomeShell `Scaffold` / `BottomNavigationBar.onTap`:**
  optionally add `HapticFeedback.lightImpact()` on tab change — but first
  test whether `BottomNavigationBar.enableFeedback` already produces a
  tick; if it does, leave the tab tap alone to avoid double-firing.
- **`android/app/src/main/AndroidManifest.xml`:** add `<uses-permission
  android:name="android.permission.VIBRATE"/>` (normal permission,
  auto-granted, no runtime prompt). Verify it appears in the merged manifest
  after the next build.
- **Test checklist (physical A16 only):** play/pause/skip each give one
  light tick; scrubbing gives ticks at detents only, one tick on grab, one
  on release; no buzzing during normal playback position updates; toggle
  Settings → Sounds and vibration → System vibration → touch interactions
  **off** and confirm silence (expected) and **on** to confirm return; test
  with Vibration intensity at Daniel's normal setting, since Samsung scales
  the feel.

## 7. On-Device Smart Queue Refill

### Recommended approach

**Two-stage, retrieval-then-rank — the same architecture production
recommenders use, shrunk to one phone.** The YouTube related-videos / Mix
pool stays the *retrieval* stage (it supplies candidates; Unbound cannot
invent tracks it has never seen). Local history only *re-ranks* those
candidates. This is the single most important design decision: it makes
overfitting structurally impossible, because no matter how strong the
affinity signal gets, it can only reorder tracks YouTube already proposed —
it can never collapse the queue to the same 5 songs, since those 5 songs are
usually not even in the candidate pool.

Concretely, per refill:

1. Fetch the candidate pool as today (related videos / Mix, ~20–25 tracks).
2. Run the planned `shapeRadioMix` bucketing first (artist buckets,
   equal-thirds interleave, consecutive-artist cap, remix/cover/live
   filter).
3. **Rank *within* each artist bucket** by a local affinity score (below),
   so the artist-ratio shaping is never disturbed by the weighting.
4. Fill ~85% of refill slots from the affinity-ranked buckets
   (exploitation) and ~15% from unplayed / low-evidence candidates in
   original pool order (exploration — epsilon-greedy, ε ≈ 0.15).
5. Never-played tracks get a **neutral prior score (0.50), not 0** —
   otherwise nothing new could ever win a ranked slot.

Signals, in order of reliability on-device: **liked (explicit, strongest)
> completion ratio > skip timing > play count (log-damped) > recency
(decay) > artist affinity (aggregated from track scores)**. Time-of-day is a
real signal in production systems but is *not* recommended here: with one
user and a handful of sessions per day it will take months to become
anything but noise, and it adds a whole extra dimension to an already sparse
dataset. Record the hour if cheap, but weight it at zero until there are
hundreds of sessions.

Spotify's internals are proprietary — no verified detail on its scoring
exists publicly, and none was found. Everything below comes from
open-source players and engineering writing instead (see Sources).

### Concrete scoring formulas with worked numbers

**Formula 1 — Point-based (verified in the wild: VinMusic).** VinMusic's
published requirements spec scores **artists** additively: +5.0 per complete
playthrough, +6.0 per repeat, +10.0 per like, +8.0 per download, −6.0 per
skip within 20 seconds; artists with skip count > play count go on a
blacklist; top-8 artists kept; max 2 songs per artist per 12-song section,
max 1 consecutive. It is simple and it works — but it is **unbounded** (a
200-play artist scores 1000+ and can never be displaced) and it scores
artists, not tracks. Good as a reference; do not adopt it verbatim. Its two
ideas worth stealing: the 20-second early-skip window, and the skip>plays
blacklist (as a soft demotion, not a hard ban — see gotchas).

**Formula 2 — Recommended for Unbound: bounded 0–1 per-track affinity.**
All terms are normalized to [0,1] so no single signal can dominate, and
every term is small-sample-shrunk so 1 play ≠ 100 plays.

```
starts        = playCount (track started and listened ≥ 5s)
completions   = plays ending naturally OR with ratio ≥ 0.80
earlySkips    = user pressed next/previous with ratio < 0.25 AND listened < 30s

completionRate = (completions + 1) / (starts + 2)          // Laplace smoothing: 1/2 prior
skipRate       = earlySkips / max(1, starts)
playTerm       = ln(1 + playCount) / ln(1 + 10)            // capped at 1.0 (10+ plays = max)
recency        = 0.5 ^ (daysSinceLastPlayed / 30)          // 30-day half-life; 1.0 if played today
likeTerm       = liked ? 1.0 : 0.0

affinity = clamp( 0.40*completionRate
                + 0.20*playTerm
                + 0.20*likeTerm
                + 0.20*recency
                - 0.25*skipRate , 0, 1)

unplayed track: affinity = 0.50   // neutral prior — discoverable, not buried
```

**Why each term:** completion ratio is the strongest *implicit* signal
(Last.fm's whole scrobble rule is built on the same idea — a play only
counts after 50% or 4 minutes); the Laplace +1/+2 stops a single completion
from scoring 1.0; `ln(1+n)` makes play 11 worth barely more than play 10
(the same log-damping production "hot" scores use to stop runaway
accumulation); the 30-day half-life means a track unplayed for 60 days keeps
only 25% of its recency term, so taste drift is handled without deleting
history; the skip penalty is subtracted *after* the weighted sum so a
heavily-skipped track can go near zero but never below it.

**Worked numbers** (all tracks 3:30 long, i.e. 210s):

| Track | History | completionRate | playTerm | like | recency | skipRate | **Affinity** |
|---|---|---|---|---|---|---|---|
| A — Joyner Lucas, liked, played 6×, 5 completions, 1 early skip (12s), last played 2d ago | starts 6, comp 5 | (5+1)/(6+2) = 0.75 | ln7/ln11 = 0.81 | 1.0 | 0.5^(2/30) = 0.96 | 1/6 = 0.17 | 0.30+0.16+0.20+0.19−0.04 = **0.81** |
| B — unknown artist, played 1×, skipped at 8s, last played 1d ago | starts 1, comp 0 | (0+1)/(1+2) = 0.33 | ln2/ln11 = 0.29 | 0 | 0.5^(1/30) = 0.98 | 1.0 | 0.13+0.06+0+0.20−0.25 = **0.14** |
| C — never played | — | — | — | 0 | — | — | **0.50 (prior)** |

Note the intended ordering: A (0.81) > C (0.50) > B (0.14). A new track
beats a *disliked* track — that is what keeps discovery alive — but a
proven favourite beats a new track. A track skipped 3 times out of 3 starts
scores ≈ 0.40·0.20 + 0.20·0.58 + 0 + 0.20·~1.0 − 0.25 ≈ 0.15, i.e.
effectively buried without a hard blacklist.

**Artist affinity** (for ranking *buckets* against each other, or for the
"sprinkle liked/recent" step): mean affinity of that artist's top 3 scored
tracks, or if the artist has no scored tracks, 0.50. Never sum raw plays
per artist — that is exactly the VinMusic unbounded-score trap.

**Alternative worth knowing — Wilson lower bound:** for a *completion rate*
treated as a binomial (completions / starts), the Wilson 95% lower bound is
the standard small-sample fix (3/3 completions → 0.29, not 1.0; 95/100 →
0.93). It is the statistically correct version of the Laplace smoothing
above. Laplace is recommended here only because it is one line of Dart with
no `sqrt` edge cases; if the team ever wants rigor, swap `completionRate`
for the Wilson bound. Either is fine; do not use the raw ratio.

**Exploration:** epsilon-greedy with ε = 0.15 (the literature's usual
0.05–0.10 is for catalogues of millions; with a 20-track pool, 0.15 buys
roughly 3 discovery slots per refill). A cheaper deterministic variant that
needs no RNG: reserve every 6th refill slot for the highest-ranked
*unplayed* candidate. Also add a **novelty bonus** alternative: `+0.05` if
the track has never been played — small enough not to swamp real signal.
Pick one mechanism, not both.

### Storage design

**Recommendation: stay on SharedPreferences — one JSON map keyed by track
ID — for now. Do not add sqflite/drift yet.**

| | SharedPreferences (JSON map) | sqflite / drift | Hive / Isar |
|---|---|---|---|
| New dependency / native risk | None — already in the app | Real: native SQLite, migrations, build config | Real: codegen / adapters; Hive's maintenance future is uncertain |
| Records at this scale | Hundreds, maybe low thousands over years | Same | Same |
| Read pattern | Load whole map once at startup, keep in memory, score from memory | Query per refill | Key lookup |
| Write pattern | 1 write per track transition (rewrite one JSON string) | 1 upsert per transition | 1 put per transition |
| Query needs | None — scoring is in-memory over ≤25 candidates; no joins, no date-range queries | Only needed if stats UI / "top tracks" screens arrive | Same as sqflite |
| Failure mode | Whole-map rewrite is O(map size) — trivial at <1,000 records (~50–100 KB JSON) | — | — |

The deciding facts: (1) there are **no queries** — refill scoring needs the
stats for ~25 candidate IDs, which is a hash lookup, not SQL; (2) write
frequency is **~1 per song played**, i.e. a few dozen writes a day at most,
each rewriting a small JSON blob — SharedPreferences handles this trivially;
(3) a new native DB dependency is a real cost in build complexity, APK size,
migration code, and a new failure surface, for zero user-visible benefit at
this scale. The honest trigger to migrate later: stats exceed ~2,000 tracks,
or a stats/top-tracks UI needs indexed queries — at that point drift
(type-safe, recommended over raw sqflite by the Flutter community) is the
right choice, and the JSON map migrates with a one-time import loop.

**Schema** — one record per track ID, stored as `Map<String, TrackStats>`
serialized to a single SharedPreferences string key (e.g.
`listening_stats_v1`):

```dart
class TrackStats {
  String trackId;            // YouTube video ID (key)
  String artist;             // denormalized — needed for artist affinity without a Track lookup
  int playCount;             // starts with ≥5s listened
  int completions;           // natural end OR ratio ≥ 0.80
  int earlySkips;            // user next/prev with ratio < 0.25 AND listened < 30s
  int lateSkips;             // user next/prev with ratio ≥ 0.25 (informational; weak signal, currently unweighted)
  int totalListenSeconds;    // sum of listened seconds across all plays
  int lastListenedSeconds;   // listened seconds on the most recent play (for skip-position analysis)
  int lastPlayedAtMs;        // epoch ms — drives recency decay
  bool liked;                // mirror of the liked-songs list (denormalized so scoring needs one lookup)
}
```

Keep `title`/`thumb` OUT of the record — stats must stay small and must not
duplicate `Track`. **Prune:** cap at 500 records; on insert past the cap,
drop the record with the oldest `lastPlayedAtMs` among unliked tracks
(liked tracks are never pruned — they are explicit preference). Also cap
`playCount` contributions implicitly via the log term, not by deleting data.

**Write discipline:** update the in-memory map on every track transition,
persist with a **debounced write** (e.g. save at most once per 30s, plus once
on app pause) rather than awaiting a disk write on the audio thread —
SharedPreferences writes are async but the JSON encode of a few hundred
records on every skip adds up. Never block playback on a stats write.

### Gotchas

1. **Overfitting / collapse:** the #1 risk. Defences, in order of
   importance: (i) local scores only *re-rank* the YouTube pool, never
   generate candidates; (ii) never-played = 0.50 prior, so new tracks
   outrank disliked ones; (iii) ε ≈ 0.15 exploration slots; (iv) log-damped
   play counts and bounded [0,1] scores, so no track can run away; (v) rank
   *within* artist buckets, never across the whole pool, so affinity can't
   break the equal-thirds shaping. If the queue ever feels samey, raise ε
   before touching any weight.
2. **Cold start:** with zero stats, every candidate scores 0.50 and the
   refill is exactly today's behaviour (pool order + shaping) — that is the
   correct fallback, not a failure. The system only starts differentiating
   after ~5–10 scored plays, and VinMusic's own spec says the same
   ("regenerate after first 5 play sessions"). Do not invent pseudo-history.
3. **Tiny-history noise:** 1 completion out of 1 start is not evidence —
   that is what the Laplace smoothing and the 0.50 prior are for. Also: do
   not compute artist affinity from a single track; require ≥2 scored tracks
   per artist or fall back to 0.50.
4. **Skip ≠ dislike, always.** A skip at 8s usually means "wrong moment /
   wrong version / accidental tap", not "hate this artist". That is why the
   penalty is −0.25·skipRate (bounded, recoverable) and not a blacklist.
   VinMusic's hard blacklist (skip count > play count) is dangerous for a
   one-user app: one bad afternoon could permanently exile an artist. If a
   blacklist is ever added, make it time-boxed (e.g. demote for 7 days) and
   user-visible.
5. **Accidental / autoplay plays pollute stats.** A track that auto-played
   while the phone was in a pocket and ran to completion is a "completion"
   the user never chose. Mitigation: only count a completion toward affinity
   if the track was *started by the user or by radio the user is actively
   listening to* — in practice, count it, but weight `playCount`
   logarithmically so passive accumulation saturates fast. Do not
   over-engineer this; the log term already caps the damage.
6. **Session end vs skip vs completion must be recorded distinctly.** The
   classic bug: app killed mid-track records nothing, so the next launch
   treats the track as unplayed; or worse, records it as a skip. Record
   partial listens.
7. **Repeat / loop mode inflates play counts.** If repeat-one is ever added,
   a track on loop would rack up dozens of "completions". Guard: count at
   most 1 completion per track per session, or exclude repeat-one plays from
   stats entirely. (Current app has no repeat-one; note it as a future
   guard.)
8. **Duration is nullable in `Track`.** Completion *ratio* needs a duration.
   If `duration == null`, fall back to absolute thresholds only (listened ≥
   240s = completion, < 30s = early skip) and never divide by null. Resolve
   durations for radio candidates where possible before scoring.
9. **Feedback loops cut both ways.** Affinity ranking shows more of what
   scored well, which generates more positive evidence for it — the classic
   filter-bubble mechanism the epsilon-greedy literature warns about (a
   synthetic study showed pure-greedy selection found the genuinely-best
   category 0.1% of the time vs 75.8% for ε=0.1 exploration, because it never
   sampled alternatives). The exploration slots are not optional polish;
   they are the mechanism that prevents the loop.
10. **Do not score on every position update.** Score once per refill from
    the in-memory map. Recomputing affinity per second is wasted work and
    risks UI jank in the audio handler isolate.

### What to integrate into Unbound

- **`lib/services/storage_service.dart` — `StorageService.recordPlayed`:**
  extend from "append to 20-item Recent list" to also upsert a `TrackStats`
  record (new `recordListenOutcome` or extend `recordPlayed` to take an
  outcome). This is where the in-memory `Map<String, TrackStats>` lives,
  where the JSON map is loaded at startup and debounced-persisted, and where
  pruning (500-cap, liked-never-pruned) happens. Add `TrackStats` as a new
  model (e.g. `lib/models/track_stats.dart`) with `toJson`/`fromJson`. Keep
  the existing 20-item Recent list untouched — it is UI history, not stats.
- **`lib/services/audio_handler.dart` — `UnboundAudioHandler._handleTrackEnded`
  and skip paths:** this is the *only* place outcomes can be observed, so it
  must classify each track ending. On natural end
  (`ProcessingState.completed`) record completion (or ratio ≥ 0.80). On user
  `skipToNext`/`skipToPrevious`, capture `player.position` at that moment
  and classify early skip (<30s and ratio <0.25) vs late skip. On app
  pause/kill mid-track, record a partial listen (`totalListenSeconds +=
  listened`, no completion, no skip) — hook into the handler's dispose /
  `onStop` and the app-lifecycle listener. Track `position` via a
  lightweight sample (record position on each transition; do not poll per
  second — or if polling, sample at most every 5s and only keep the latest
  value). Pass `listenedSeconds`, `durationSeconds`, and the outcome enum to
  StorageService.
- **`lib/services/audio_handler.dart` — `_maybeRefill` (lines ~415–470):**
  after fetching the candidate pool and after `shapeRadioMix` bucketing,
  rank *within* each bucket by `affinity(track)` (new scorer, see below),
  then interleave buckets as today; reserve ~15% of appended slots (e.g.
  every 6th slot) for the highest-ranked unplayed candidate in pool order.
  The scorer needs the stats map (from StorageService) and the liked list —
  both already in memory. No new network calls: scoring is pure local
  computation over ≤25 candidates, microseconds.
- **Planned `shapeRadioMix` in `lib/services/youtube_service.dart`:** keep
  shaping and scoring separate — shaping decides *which artists and how many
  of each* (equal thirds, consecutive cap, remix/cover/live filter); scoring
  decides *order within each artist's bucket*. Also use artist affinity here
  for the "sprinkle liked/recent tracks" step: prefer liked/recent tracks
  whose artist is already in the bucket set, ranked by track affinity. Do
  not let affinity re-weight the bucket *sizes* — that would silently
  reintroduce seed-artist dominance through the back door.
- **`lib/services/recommendations.dart`:** reuse the same `affinity()`
  scorer for the "own mix" and Quick Picks paths so all surfaces agree on
  what "liked" means; the existing position × recency scoring for external
  mode can stay, but the local-signal scorer should be the single shared
  function (new file, e.g. `lib/services/affinity.dart`, used by both
  `audio_handler.dart` and `recommendations.dart`). Keep the opt-in external
  mode's behaviour unchanged.
- **Event/threshold contract** (implement in the audio handler): track
  started → record `startedAt` + position 0; natural end → completion; user
  next/prev → skip with position; app backgrounded/killed mid-track →
  partial listen. Thresholds: **early skip = listened < 30s AND ratio <
  0.25** (30s from Last.fm's scrobble floor; 20s in VinMusic — 30s is the
  more conservative, better-evidenced choice); **completion = natural end OR
  ratio ≥ 0.80**; **partial = everything in between** (adds to
  `totalListenSeconds`, counts as a start, counts as neither completion nor
  skip). Tracks shorter than 30s can never be early-skipped or scrobbled
  (Last.fm rule: never counts under 30s) — treat a <30s track played to the
  end as a completion.

## Sources

Every source used, grouped by item. Installed package sources are listed
with their local paths — they are the authority for version-specific claims.

### Installed package sources (primary evidence — read directly)

- just_audio 0.10.6 — `~/.pub-cache/hosted/pub.dev/just_audio-0.10.6/lib/just_audio.dart`
  (`positionStream` 16–200 ms adaptive ticks, `createPositionStream`,
  `durationStream`, `bufferedPositionStream`, `handleInterruptions` block
  lines 370–410, `AudioPlayer.pause()` clearing `_playInterrupted` ~line
  1131, `setAudioSources` line 877, `@Deprecated('Use
  AudioPlayer.setAudioSources instead')` on `ConcatenatingAudioSource` line
  2921, CHANGELOG line 40 deprecation note)
- audio_service 0.18.19 — `~/.pub-cache/hosted/pub.dev/audio_service-0.18.19/lib/audio_service.dart`
  (`PlaybackState` constructor/`position` getter/`updatePosition` docs
  lines 140–300, `SeekHandler` mixin line 3220, platform seek dispatch
  lines 3970–3971, `_observeMediaItem` art-caching flow lines 1029–1095,
  `_loadArtwork` lines 1235–1270, `MediaItem.artHeaders`, `AudioServiceConfig.artDownscaleWidth/Height`,
  `androidArtDownscaleSize` line 1393); `android/src/main/java/com/ryanheise/audioservice/AudioService.java`
  (`loadArtBitmap` lines 175–250, `setMetadata` lines 786–810,
  `artBitmapCache`, `builder.setLargeIcon` line 629)
- audio_session 0.2.4 — `~/.pub-cache/hosted/pub.dev/audio_session-0.2.4/lib/src/core.dart`
  (`becomingNoisyEventStream` lines 184–187), `lib/src/android.dart`
  (method-channel `onBecomingNoisy` lines 45–46),
  `android/src/main/kotlin/com/ryanheise/audio_session/AndroidAudioManager.kt`
  (`registerNoisyReceiver` ~line 654, `ACTION_AUDIO_BECOMING_NOISY`
  IntentFilter line 666)
- youtube_explode_dart 3.1.0 — `~/.pub-cache/hosted/pub.dev/youtube_explode_dart-3.1.0/lib/src/common/thumbnail_set.dart`
  (all five thumbnail URL templates; `maxResUrl`/`standardResUrl` "Not
  always available")
- Flutter SDK 3.35.7 (local `~/workspace/flutter-sdk`) —
  `packages/flutter/lib/src/services/system_chrome.dart` (edge-to-edge
  default, `SystemUiMode.edgeToEdge`, `SystemUiOverlayStyle` docs),
  `packages/flutter/lib/src/services/haptic_feedback.dart`
  (`HapticFeedback` methods), `packages/flutter/lib/src/material/bottom_navigation_bar.dart`
  (`additionalBottomPadding = MediaQuery.viewPaddingOf(context).bottom`,
  line 1106), `packages/flutter/lib/src/material/scaffold.dart`
  (body/bottomNavigationBar layout), `engine/src/flutter/shell/platform/android/AndroidManifest.xml`
  (no `VIBRATE` declared)
- Unbound codebase (verified by reading) — `lib/main.dart` (AudioService
  config, HomeShell Scaffold, body `SafeArea`), `lib/widgets/widgets.dart`
  (`PlayerBar` 324–429), `lib/services/audio_handler.dart`
  (`PlaybackUiState`, `_emit`, `seek`, `_maybeRefill`, interruption
  listener, `pause`), `lib/services/youtube_service.dart` (`_toTrack`
  thumb selection), `lib/services/downloads_service.dart` (audio-only
  downloads; no cover saving), `lib/services/storage_service.dart`
  (`recordPlayed`), `lib/models/track.dart`, `android/app/src/main/AndroidManifest.xml`
  (permissions; no `VIBRATE`; no edge-to-edge opt-out), `pubspec.lock`
  (pinned versions incl. rxdart 0.28.0)

### Item 1 — Now Playing sheet

- https://api.flutter.dev/flutter/widgets/DraggableScrollableSheet/snap.html (official: snap/fling semantics, animateTo bypasses snap)
- https://api.flutter.dev/flutter/widgets/DraggableScrollableSheet/expand.html (official: `expand`)
- https://www.getwidget.dev/blog/flutter-bottomsheet-widget/ (persistent vs modal; `isScrollControlled: true` 50% cap; `expand: false` in modal)
- https://copyprogramming.com/howto/dart-on-tap-show-draggablescrollablesheet-flutter-code-example (sizes, snapSizes, controller; secondary — corroboration only)
- https://copyprogramming.com/howto/dart-draggable-scrollable-sheet-flutter-is-not-dragable (must pass builder's ScrollController; snapAnimationDuration 3.7+)
- http://gitdiagram.com/gokadzev/musify (Musify structure: `lib/screens/now_playing_page.dart` + `lib/widgets/mini_player.dart` — full-page model, mechanism reference only)
- https://github.com/KRTirtho/spotube/releases/tag/v3.0.0 (Spotube: floating mini-player + full PlayerView model)
- https://pub.dev/documentation/material_ui/1.10.0/material_ui/Scaffold-class.html (Scaffold + DraggableScrollableSheet >70% scrim/FAB behaviour — a `material_ui` package mirror of Scaffold docs, not api.flutter.dev; corroboration only)

### Item 2 — Seek scrubbing + gapless

- https://pub.dev/packages/just_audio/versions/0.10.3/example (official example: `Rx.combineLatest3` PositionData, `StreamBuilder<PositionData>`, `onChangeEnd: _player.seek`, spinner on loading/buffering)
- https://pub.dev/packages/just_audio/versions/0.10.5/example (same official example, 0.10.5)
- https://pub.dev/documentation/fepe_just_audio/latest/just_audio/AudioPlayer-class.html (positionStream 16–200 ms interval; `createPositionStream` "will not emit values while audio playback is paused or stalled"; `duration` null if unknown — a fork's doc mirror of the just_audio API; same text appears in the official docs)
- https://pub.dev/packages/audio_service (README: `SeekHandler` mixin, `updatePosition` "do not broadcast position changes continuously… listeners will be able to project," `AudioService.position` stream)
- https://pub.dev/packages/audio_service/versions/0.18.17/example (official example: `AudioPlayerHandler extends BaseAudioHandler with SeekHandler`, `_transformEvent` with `updatePosition: _player.position`, `_mediaStateStream` via `AudioService.position`, `SeekBar(onChangeEnd: _audioHandler.seek)`)
- https://pub.dev/documentation/audio_service/0.18.17/audio_service/PlaybackState-class.html (verified: constructor has `updatePosition`, no `position` param; `position` is a derived getter)
- https://pub.dev/documentation/audio_service/0.18.17/audio_service/PlaybackState/copyWith.html (`copyWith` sets `updatePosition` to `position` unless replaced)
- https://pub.dev/packages/just_audio/changelog (0.10.x changelog; ConcatenatingAudioSource deprecation)
- https://pub.dev/documentation/just_audio/0.10.5/just_audio/AudioPlayer/AudioPlayer.html (`AudioPlayer` constructor: `useLazyPreparation` default true)
- https://readmedium.com/managing-playlists-in-flutter-with-just-audio-c4b8f2af12eb (ConcatenatingAudioSource gapless/prefetch explanation)
- https://www.ashishbhakhand.com/blog/flutter-background-audio-audio-service-just-audio (handler broadcasting pattern, `updatePosition: _player.position`)
- https://github.com/ryanheise/audio_service/issues/1115 (real-world handler doing per-position `copyWith(updatePosition:)` — a workaround pattern, not the recommendation)
- https://deepwiki.com/944095635/dm-music-flutter/4.3.5-playpage-full-screen-music-player and https://deepwiki.com/944095635/dm-music-flutter/5.3-music-control-components (DM Music `isDragProgress` flag pattern; ~100 ms position updates)
- https://developer.android.com/reference/android/media/session/PlaybackState (Android `PlaybackState`, `ACTION_SEEK_TO`)
- https://android-developers.googleblog.com/2020/08/playing-nicely-with-media-controls.html (Google: duration missing → no seek-bar progress indicator; `ACTION_SEEK_TO` → draggable marker)
- https://blog.redlinesoft.net/posts/flutter-web-audio-player/ (just_audio 0.10.6 notes: `playing` vs `processingState == ready`, web has no gapless — corroboration only)

### Item 3 — Notification artwork

- https://pub.dev/packages/audio_service/changelog (0.18.0 art performance, 0.18.5 `content://`, 0.18.6 `artHeaders`, 0.17.0 `artUri` → `Uri`)
- https://pub.dev/documentation/audio_service/0.18.17/audio_service/MediaItem/artHeaders.html (`MediaItem.artHeaders`)
- https://github.com/ryanheise/audio_service/issues/294 (art downscaling to 96×96 on lock screen)
- https://github.com/ryanheise/audio_service/issues/667 (queue change loads all album arts)
- https://github.com/ryanheise/audio_service/issues/784 (`content://` art)
- https://github.com/ryanheise/audio_service/issues/1117 (`file://` art missing in Android Auto)
- https://developer.android.com/media/legacy/mediasession (album art max 320×320dp, scaled down if larger)
- https://developer.android.com/media/platform/output (`ACTION_AUDIO_BECOMING_NOISY`, register receiver on play, unregister on stop)
- https://developer.android.com/reference/kotlin/android/app/Notification.MediaStyle (`setLargeIcon()` bitmap treated as album artwork)
- https://developers.google.com/youtube/v3/docs/thumbnails (`maxres` 1280×720 "available for some videos", `high` 480×360)
- https://www.metaclipper.com/youtube-thumbnail-resolution and https://www.clickmate.online/youtube-data-api-v3-thumbnail-url-guide.html (maxres 404 on older/SD videos, hqdefault near-universal)
- https://cocalc.com/github/chromium/chromium/blob/main/components/browser_ui/media/android/java/src/org/chromium/components/browser_ui/media/MediaNotificationImageUtils.java (Chromium media-image sizing: 512px high-end / 256px low-end)

### Item 4 — Becoming noisy

- https://pub.dev/packages/audio_session — "if the audio plugin doesn't handle unplugged headphone events, you can respond to these yourself by listening to `session.becomingNoisyEventStream`"
- https://pub.dev/packages/audio_session/example and https://github.com/ryanheise/audio_session/blob/master/example/lib/main.dart (official example)
- https://pub.dev/documentation/just_audio/0.10.5/just_audio/AudioPlayer/AudioPlayer.html (published 0.10.5 constructor source — interruption handling)
- https://github.com/TheZupZup/Linthra/pull/175 and https://github.com/thezupzup/linthra/blob/HEAD/docs/audio-bluetooth-cpu-audit.md (Linthra — a just_audio/audio_service app that hit the same self-resume bug and fixed it by classifying transient vs permanent focus loss and clearing resume state on becoming-noisy; mechanism reference only)

### Item 5 — Edge-to-edge

- https://docs.flutter.dev/release/breaking-changes/default-systemuimode-edge-to-edge
- https://api.flutter.dev/flutter/services/SystemChrome/setEnabledSystemUIMode.html
- https://api.flutter.dev/flutter/services/SystemUiOverlayStyle-class.html
- https://api.flutter.dev/flutter/material/Scaffold-class.html
- https://api.flutter.dev/flutter/material/BottomNavigationBar-class.html
- https://developer.android.com/about/versions/15/behavior-changes-15
- https://developer.android.com/develop/ui/compose/system/insets
- https://developer.android.com/codelabs/edge-to-edge
- https://github.com/po4yka/lenswake/blob/HEAD/docs/research/android-15-17-system-insets.md
- https://github.com/ichintansoni/skills-master/blob/HEAD/plugins/skills-master-android-lang-tooling/skills/edge-to-edge-compat/SKILL.md
- https://rapidlabs.dev/articles/android-edge-to-edge/
- https://github.com/zakariaf/flutter-skills/blob/HEAD/skills/adaptive-layout/references/window-size-classes.md
- https://github.com/bow-t/bow-skills/blob/HEAD/plugins/flutter/skills/flutter-responsive-and-adaptive-layout/SKILL.md
- https://responsive.akclnt.com/guides/safe-area-notch
- https://pub.dev/packages/easy_system_bars
- https://www.codegenes.net/blog/how-to-make-flutter-app-draw-behind-android-navigation-bar-and-make-navigation-bar-fully-transparent/
- https://copyprogramming.com/howto/flutter-strange-padding-on-top-of-status-bar
- https://copyprogramming.com/howto/flutter-safe-area-issue
- https://copyprogramming.com/howto/flutter-background-of-unsafe-area-in-safearea-widget
- https://copyprogramming.com/howto/material-component-tab-bar-bottom-navigation
- https://copyprogramming.com/howto/how-to-navigate-with-buttons-and-bottomnavigationbar-flutter
- https://copyprogramming.com/howto/icon-s-color-in-status-bar-flutter
- https://copyprogramming.com/howto/flutter-how-to-change-system-navigation-bar-color

### Item 6 — Haptics

- https://api.flutter.dev/flutter/services/HapticFeedback-class.html
- https://api.flutter.dev/flutter/services/HapticFeedback/lightImpact.html
- https://api.flutter.dev/flutter/services/HapticFeedback/mediumImpact.html
- https://api.flutter.dev/flutter/services/HapticFeedback/heavyImpact.html
- https://api.flutter.dev/flutter/services/HapticFeedback/selectionClick.html
- https://api.flutter.dev/flutter/services/HapticFeedback/vibrate.html
- https://api.flutter.dev/flutter/services/HapticFeedback/successNotification.html
- https://github.com/flutter/flutter/pull/167362 (CupertinoSlider haptics — detent/throttle pattern)
- https://blog.redlinesoft.net/posts/vibration-flutter-haptics/
- https://pub.dev/packages/haptic_feedback
- https://pub.dev/packages/haptic_kit
- https://pub.dev/packages/tactile_fluid_slider/versions/1.1.0 ("magnetic haptic detents")
- https://pub.dev/documentation/flutter_vibrate/latest/
- https://pub.dev/packages/flutter_awesome_snackbar
- https://flutterexperts.com/vibration-in-flutter/
- https://developermemos.com/posts/implement-vibration-flutter/
- https://www.samsung.com/ca/support/mobile-devices/sounds-vibrations-and-notifications-on-your-samsung-galaxy-devices/
- https://www.samsung.com/us/support/answer/ANS10004542/
- https://www.samsung.com/uk/support/mobile-devices/how-do-i-set-my-samsung-galaxy-device-to-vibrate/
- https://sammyguru.com/that-random-vibration-on-your-one-ui-7-phone-is-sunlight-can-you-turn-it-off/
- https://support.google.com/accessibility/android/answer/9078946
- https://www.flutternews.com/blog/what-s-new-in-flutter-335
- https://www.200oksolutions.com/blog/whats-new-in-flutter-3-35-faster-hot-reload-webassembly-readiness-widget-previews-ai-powered-tools/

### Item 7 — Smart queue refill

- VinMusic smart-playlist requirements spec (concrete point formula, skip window, diversity caps, cold start) — https://github.com/vinrawa/vin-music-v2/blob/HEAD/.kiro/specs/smart-playlist-recommendations/requirements.md
- Segue (Flutter open-source player) — "My wave" learns from completions/skips, smart playlists — https://github.com/segue-app/segue
- LastWave-Native changelog — `SongPlayStatsEntity` / `SongPlayStatsDao` local per-track stats (total play time, skip counts) — https://github.com/clash-projects/lastwave-native/blob/HEAD/CHANGELOG.md
- Last.fm scrobble rule (50% or 4 min, whichever first; never under 30s) — https://support.last.fm/t/spotify-what-defines-a-song-as-scrobbled/48256/5 and https://trackdown.yyyokel.com/guides/what-is-scrobbling/
- GhostWave (local-first player) — completed plays defined as ≥30s or ≥50% duration vs skips — https://devpost.com/software/ghostwave-ep01zw
- Recommendation-system design, two-stage retrieval/ranking and multi-objective scoring (`w₁·P(click) + w₂·P(complete) + w₃·P(rating≥4) − w₄·P(skip<10s)`) — https://sharief007.github.io/dev-docs/design-concepts/ml/recommendation-systems/
- Epsilon-greedy / cold start / exploration vs exploitation — https://codemia.io/courses/ml_systems_and_infrastructure/recommendation_systems ; https://medium.com/activated-thinker/your-music-algorithm-knows-what-you-like-what-is-it-missing-39fc8ec8db3f ; https://datafield.dev/algorithmic-addiction/part-04/chapter-22/
- Wilson lower bound + exponential recency decay (30-day half-life example, worked numbers) — https://docs.claudefi.com/skills/effectiveness ; https://blog.lohi2.com/discovery/rank/ ; https://github.com/an1sh-r/steam-content-recommender-system/blob/HEAD/docs/ENGINEERING.md
- Flutter local-storage comparison (SharedPreferences vs Hive vs sqflite/drift) — https://flutter.unisbadri.com/en/local-storage/overview/ ; https://pub.dev/documentation/torex_local_store/latest/ (benchmark table)
- Musify context (recently-played cap raised 50 → 250 in v10.0.0; no per-track stats published) — https://receiptifylogin.us/musify-apk/

## What was NOT verified

Be honest about these — do not treat them as established when building.

- **Item 1:** the exact `Scaffold.bottomSheet` vs `BottomNavigationBar`
  layering order (whether a sheet in `bottomSheet:` covers the nav bar) —
  test on the A16; the in-body `Stack` alternative sidesteps it.
  `DraggableScrollableController.size` / listener semantics for hiding the
  nav bar on expansion, and the exact `shouldCloseOnMinExtent` default —
  confirm from api.flutter.dev at implementation time.
- **Item 2:** the default `seekForward`/`seekBackward` step supplied by
  `SeekHandler` (commonly ±10 s in examples — verified from source as
  continuous ±10 s at 1 s intervals while held, but the one-shot
  `fastForward`/`rewind` interval comes from
  `AudioService.config.fastForwardInterval` / `rewindInterval`, whose
  defaults were not checked). No just_audio documentation was found stating
  `seek()` while `loading`/`buffering` is an error — the recommended seek
  guard is UI-level/defensive, not API-mandated.
- **Item 3:** exact SystemUI rendering/cropping of a 16:9 thumbnail in the
  Android 14/15 notification shade and on Samsung One UI (A16 5G) — no
  authoritative doc states the crop rule for `MediaStyle` large icons.
  Android Auto + `file://` art (issue #1117) is a user report with no
  maintainer response — plausible but not confirmed against 0.18.19. Live
  `maxresdefault.jpg` 404 behaviour was established from docs/secondary
  sources, not from a live request.
- **Item 4:** `audio_service` exact pin — the installed cache is 0.18.19;
  the 0.18.x changelog shows no art-related breaking change across the 0.18
  line, and the just_audio 0.10.6 vs 0.10.5 source was spot-checked with no
  behavioural difference found on these paths.
- **Item 5:** the LeanCode "Mastering Edge-To-Edge in Flutter" article
  (linked from the Flutter breaking-change doc) was not retrievable. Which
  One UI / Android version is currently on Daniel's A16 was not verified
  (shipped Android 14 / One UI 6.1; Android 15 / One UI 7 rollout varies).
  Flutter 3.35.7 patch-level specifics — no 3.35.7-only edge/haptic change
  was found in the release notes searched; the operative change
  (edge-to-edge default) is 3.27-era. Secondary sources disagree on the
  3.35 minSdk bump (21 vs 24); neither value is asserted.
- **Item 6:** `warningNotification` / `errorNotification` Android constants
  were not opened/verified — no mapping is asserted for them. Daniel's A16
  vibrator hardware was not verified. `BottomNavigationBar.enableFeedback`
  default was not verified — test on-device whether tab taps already tick
  before adding a manual haptic.
- **Item 7:** no open-source player was found publishing a complete,
  production-tested per-track affinity formula with tuned weights.
  VinMusic's point values are a spec, not a measured result; Segue's "My
  wave" describes the *behaviour* but not its formula; LastWave's
  `SongPlayStatsEntity` confirms the *schema pattern* but its scoring code
  was not inspected. The weights in Formula 2 (0.40/0.20/0.20/0.20, −0.25
  skip, 30-day half-life) are therefore a synthesis from the patterns
  above, not a copied proven formula — they are principled starting values
  that will need tuning by feel. Spotify internals: nothing verified beyond
  the fact that they are proprietary. Hive's current maintenance status was
  not verified. just_audio / audio_service event specifics (exact
  `ProcessingState` transitions, whether position survives a kill) were not
  re-verified against the installed package versions for the kill-mid-track
  hook — the implementer should confirm that hook works on the real device
  before relying on partial-listen recording.
- **General:** no on-device testing was done in this research pass — every
  integration note that says "verify on the A16" means it. The report's
  job is to make the build plan correct on paper; the phone is where it
  gets proven.
