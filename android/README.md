# Unbound Music — Android app (Flutter)

Personal music player for Android. Free and ad-free forever, for one
person. Built from scratch 2026-11-11 after Daniel ordered the old repo
torn down and the app rebuilt. No code was copied from the old app —
this is a fresh build from the approved design decisions.

## What it is

- **Five tabs:** Home, Search, Library, Queue, Radio.
- **Playback:** `just_audio` inside an `audio_service` foreground
  service, so music keeps playing with the screen off, from the lock
  screen, headphones and the car. Playback truth built in from the
  start: `wantsPlaying` (what you asked for) is split from `isPlaying`
  (what the player confirmed). The button shows "Starting…" until the
  player confirms Playing; tapping while Starting cancels the start.
- **Queue:** Repeat On loops; Repeat Off ends in one clean, visible
  finished state. Unplayable tracks are skipped; if every track fails,
  playback stops cleanly with a plain message. Radio refills near the
  end of the queue from YouTube's real related-videos data, guarded so
  it cannot race the last track.
- **Search:** one box, direct, through the public
  `youtube_explode_dart` library. No API key, no quota, no proxy. A
  search that finds nothing says so; a search that fails says so.
  Never a silent empty list.
- **Library honesty:** Recently Played is a real history, separate
  from the queue. Downloads are real files stored on this phone — only
  files actually on disk are listed. No dead Spotify import.
- **Design:** void `#050505`, ink `#0b0b12`, violet `#8b5cf6`, sky
  `#38bdf8`, mint `#34d399`. Space Grotesk headlines, Inter body.
  Frosted glass on the now-playing card and player bar only.
  Equalizer bars tied to real playback state. No 3D, no fake content.

## The grey lane, stated plainly

This app talks to YouTube's undocumented internal endpoints
(Innertube) while pretending to be one of YouTube's own apps, to get
direct audio addresses. That is how it delivers background play,
offline downloads, and real related-videos radio with no quota. The
trade, stated in the code and here: it can break whenever YouTube
changes its hidden systems, and a play here is not counted the same
way as a play through the official player. The web app stays in the
official lane; this app is where the direct path lives, by Daniel's
explicit, eyes-open choice (Decision 7).

## Build it

```bash
flutter pub get
flutter analyze
flutter build apk --debug
```

The APK is built for sideloading (F-Droid / GitHub Releases). There
is no Play Store build.

## What it will never do

No ads from the app, no tracking, no account wall, no paywall — ever.

## Files (plain words)

```
lib/
  main.dart                    App start: builds the services, starts the
                               foreground audio service, shows the five tabs.
  app_state.dart               The brain: holds the queue, the current
                               track, the search results, the liked songs,
                               the playlists, and every user action
                               (play / pause / next / like / search / radio).
  models/track.dart            The shared data model: Track, Playlist,
                               RecentlyPlayedEntry — identical in shape to
                               the web app's src/types.ts.
  theme/unbound_theme.dart     Colours, text styles, the glass look.
  services/
    youtube_service.dart       Talks to YouTube: search, stream URLs,
                               related videos (radio), video details.
    audio_handler.dart         The foreground service brain: owns the
                               just_audio player, the notification, the
                               media-session controls, wantsPlaying /
                               isPlaying, queue-end rules, radio refill.
    storage_service.dart       Saves everything locally: queue, liked
                               songs, playlists, Recently Played, settings.
    downloads_service.dart     Real downloads: fetches the audio file,
                               saves it as tracks/<id>.m4a, lists/deletes.
    recommendations.dart       "More like this": related videos plus
                               Daniel's own listening history (the Musify
                               "magic if" idea, rebuilt, not copied).
    cover_art.dart             Cover art for the notification and the
                               lock screen, with a cache.
  widgets/widgets.dart         The shared pieces: track row, play/pause
                               button, EQ bars, Playing pill, glass panel,
                               seek bar, player bar.
  screens/screens.dart         The five tabs: Home, Search, Library,
                               Queue, Radio.
```

## Build prerequisites (all under `~/workspace`, nothing system-wide)

- Flutter SDK 3.35.7 at `~/workspace/flutter-sdk`
- Temurin JDK 17 at `~/workspace/jdk17`
- Android SDK at `~/workspace/android-sdk`
  (cmdline-tools, platform-tools, platforms;android-35 and android-36,
  build-tools;35.0.0, ndk;27.0.12077973, cmake;3.22.1)

```bash
export PATH="$HOME/workspace/flutter-sdk/bin:$PATH"
export JAVA_HOME=$HOME/workspace/jdk17
export ANDROID_HOME=$HOME/workspace/android-sdk
# Java's default IPv6 loopback hangs against Gradle on this VM — force IPv4.
export _JAVA_OPTIONS="-Djava.net.preferIPv4Stack=true"
export JAVA_OPTS="-Djava.net.preferIPv4Stack=true"
cd ~/workspace/unbound-music-android
flutter pub get
flutter analyze
flutter build apk --debug --no-android-gradle-daemon
```

The debug APK lands at
`build/app/outputs/flutter-apk/app-debug.apk`.

## Build result (2026-11-11)

- `flutter analyze`: **No issues found.**
- `flutter build apk --debug`: **✓ Built** — `app-debug.apk`,
  153,331,794 bytes (~146 MB), package `com.unbound.music` 0.1.0,
  verified with `aapt dump badging` (launchable MainActivity,
  libflutter.so present).

Environment fixes that made the build work here (all in this repo or
`~/workspace`, documented so they are not re-derived):

- **Egress proxy + Java trust store.** Gradle's downloads go through
  the sandbox egress proxy (MITM, Hatch CA). Java uses its own
  cacerts, so the Hatch CA was imported into the JDK's cacerts
  (`keytool -importcert -alias hatch-egress-ca`). The CA rotates
  (it did once, 2026-11-11); if Gradle downloads start failing
  with PKIX errors, compare the fingerprint with
  `/usr/local/share/ca-certificates/hatch-egress-ca.crt` and
  re-import. The proxy password in `/root/.gradle/gradle.properties`
  also rotates — refresh it from current `$https_proxy` before a
  build. (Note: `/root/.gradle` is wiped on environment restart —
  see below.)
- **Local Maven mirror for the Flutter engine.**
  `storage.googleapis.com` stalls for Gradle's HttpClient through
  this proxy ("Read timed out" on the tiny engine POMs) while curl
  fetches them in under a second. The debug engine artifacts
  (`io.flutter:armeabi_v7a_debug`, `arm64_v8a_debug`, `x86_64_debug`,
  `flutter_embedding_debug`, version
  `1.0.0-035316565ad77281a75305515e4682e6c4c6f7ca` — note: these are
  **jars**, not aars; the POM says `<packaging>jar</packaging>`) were
  downloaded with curl into `~/workspace/local-maven` and wired in
  first via `dependencyResolutionManagement` in
  `android/settings.gradle.kts` (`PREFER_SETTINGS` — project repos
  still fall back). On a normal network this is unnecessary and can
  be removed.
- **Jetifier off.** `android.enableJetifier=false` in
  `android/gradle.properties`: every dependency is already AndroidX,
  and Jetifier ran out of heap transforming the 100–158 MB debug
  engine jars on this ~6 GB VM.
- **No hand-written `package.xml` files** in the Android SDK:
  AGP's parser rejects them (`UnmarshalException: unexpected
  element (localPackage)`). Components are found by directory /
  source.properties / android.jar without them.
- **If the environment restarts:** `~/workspace` survives, but
  `/root/.gradle` (gradle.properties, wrapper dist, dependency
  cache) and `/tmp` are wiped. Recreate `/root/.gradle/gradle.properties`
  (proxy + `org.gradle.daemon=false` + IPv4 flag) from current
  `$https_proxy`, re-import the Hatch CA if rotated, and re-place
  the Gradle 8.12 distribution (zip kept in
  `~/workspace/sdk-downloads/gradle-8.12-all.zip`).

## Open points (not decided, not guessed)

1. **Release signing.** No keystore exists. A release APK needs one
   created and stored safely; the debug APK is fine for on-phone
   testing.
2. **POST_NOTIFICATIONS runtime permission (Android 13+).** The
   permission is declared in the manifest, but nothing asks the user
   for it yet. First-launch prompt still to add.
3. **Google Fonts are fetched at runtime.** Space Grotesk and Inter
   download from Google on first launch; until then the system font
   shows. Bundling the fonts into the APK (offline-first) is the
   cleaner fix and is still to do.
4. **PO-token / Innertube fragility.** The grey lane depends on
   YouTube's internal endpoints. If YouTube changes them, search /
   streams break until `youtube_explode_dart` is updated. This is
   the same fragility Musify lives with; nothing here fixes it.
5. **No on-device test yet.** The debug APK builds and is verified
   on this machine, but has not been installed on Daniel's Galaxy
   A16 5G. The screen-off / lock-screen / headphone tests still
   need doing on the phone.
6. **Artist radio vs. artist mix.** Radio refills from related
   videos (YouTube's data). A "local mix" fallback from Daniel's
   own library (the Musify-style fallback) is designed but not
   wired in yet.
7. **Search scope.** Search currently returns videos only
   (`VideoSearchList`). Channel / playlist search results are not
   shown yet.
8. **Name question (not decided).** The app was renamed **Unbound
   Muzik** on 2026-11-11 (new GitHub repo `Zer0FuKsGiv3n/Unbound-Muzik`)
   — but this APK scaffold still says "Unbound Music" (manifest
   label, package `com.unbound.music`, README). Whether the APK
   should also be renamed has not been decided.
