# Artist Radio Deep Dive — getting Spotify-quality radio without building a recommendation engine

Filed 2026-11-13. Research only — no code was written or changed.

**The question:** Daniel loves Spotify's "go to artist radio." It does not give 100 songs by one artist, and it does not give knock-off remixes. It gives an equal ratio of (a) the originating artist, (b) artists of the same caliber and skill, and (c) new up-and-coming artists with a similar sound. He considers Spotify the gold standard — "wins gold," others make solid attempts but none get close. Can Unbound do something like that without building a recommendation engine and without becoming high-maintenance?

**The short answer:** Yes — closer than you might expect, but not all the way. The recommendation engine already exists: it is YouTube Music's own radio system, and Unbound can use it. The work is (1) switching the radio source from raw YouTube related videos to YouTube Music's Mix playlists, and (2) shaping the mix into the ratio in Unbound's own code. YouTube keeps doing the recommending; Unbound only picks and arranges. What no YouTube-based approach can match is Spotify's audio analysis and its listening data — the honest limits are in section 10.

## 1. What Spotify's artist radio actually does

Spotify's artist radio is not a search. It is a recommendation:

- It starts from an artist entity, not a single song.
- Its engine combines three things no single YouTube call has: **audio analysis** (tempo, key, energy, mood of every track), **collaborative filtering** (what people who listen to artist X also listen to, across billions of sessions), and **editorial/new-music data** (which artists are breaking right now).
- The result feels like a ratio because the engine is explicitly balancing familiarity (the seed artist), similarity (same-caliber artists), and discovery (emerging artists). It can do that because it has a similarity score for every artist pair.
- It also has a taste profile for the listener, so the same artist's radio is different for two different people.

The key point for this dive: **Spotify's edge is a similarity model plus listening data.** Unbound cannot build either. What Unbound can do is borrow YouTube Music's similarity model — because YouTube Music has already built one — and shape the output.

## 2. What Unbound's Radio does today

Current state (verified in the code, 2026-11-13):

- `lib/services/youtube_service.dart`, `fetchRelatedTracks(track)`: calls `_yt.videos.getRelatedVideos(video)` — YouTube's "what's next" graph for that video — and takes the results **in YouTube's order**, with no ratio shaping.
- `fetchArtistRadioTracks(artist)`: fallback that runs three searches (`"$artist music"`, `"$artist songs"`, `"$artist official video"`), dedupes, shuffles, stops at 20.
- `lib/services/audio_handler.dart`, `_maybeRefill()`: when the queue is within 5 tracks of the end, it fetches related tracks of the current track and appends all fresh ones. `_pullOneMoreRelated()` takes the first related track not already in the queue.
- `lib/screens/screens.dart`, Radio tab: Daniel types an artist name and taps "Start Radio." There is no "go to artist radio" on a search result — you cannot start radio from a song you just found.
- `lib/models/track.dart`, `Track`: id, title, artist, thumb, duration, source. **No view count, no popularity signal at all.** The `_toTrack()` mapper in `youtube_service.dart` drops everything except those fields.

So today the radio is "YouTube's related videos, in YouTube's order." That is a real recommendation signal, but it is not shaped, and the entry point is a text field rather than a tap on a result.

## 3. Finding 1: YouTube Music Mix playlists (RDAMVM) — the single biggest upgrade

### What a Mix is

YouTube auto-generates "Mix" playlists. There are two kinds that matter here:

| Playlist ID | What it is | Content |
|---|---|---|
| `RD<videoId>` | Regular YouTube autoplay mix ("Mix - …") | Music **and** non-music: live performances, covers, vlogs, reactions — anything YouTube thinks will keep you watching |
| `RDAMVM<videoId>` | **YouTube Music mix** ("Mix - [Artist]") | **Music only**, built by YouTube Music's recommendation engine |

`RDAMVM` stands for Radio Autoplay Mix Video Music. Multiple independent sources confirm the format and the distinction:

- NewPipe's extractor docs: "Ids from a YouTube Music Mix start with `RDAMVM` or `RDCLAK`."
- Archiveteam's YouTube technical details: `RDAMVM<videoID>` — Mix, "unviewable, playnext and watch functional."
- The bedrock-api YouTube provider docs: "`GetSimilarTracks()` leverages YouTube Music's auto-radio feature… playlist ID format `RDAMVM{videoId}`… The `Next` endpoint with a RDAMVM playlist ID returns a full queue of related tracks without requiring an authenticated user or playlist subscription. This is YouTube Music's recommendation engine… The RDAMVM format is specific to YouTube Music and produces music-focused recommendations. Regular YouTube's autoplay (`RD{videoId}`) would include non-music content like music videos, live performances, and covers."
- Beatbump's downloader: "For song mixes (auto-generated playlists based on a seed track), `PopulateSongMixTask`… calls `yt_api.Next(videoID, "RDAMVM"+videoID, yt_api.IOS_MUSIC, params)` to fetch the next batch of related tracks."

### Why this is better than raw related videos

Related videos (what Unbound uses now) come from the **watch page** — the "Up next" list. That list optimizes for watch time across all of YouTube. The RDAMVM Mix comes from **YouTube Music's** engine, which optimizes for music listening: same-artist tracks, same-genre artists, and discovery. It is the closest thing to Spotify's radio that exists on YouTube's public surface, and it is built by the same company from music-listening data rather than video-watch data.

### Can youtube_explode_dart fetch a Mix?

Yes — by design. In `youtube_explode_dart` 3.1.0, `PlaylistPage.get()` (in `lib/src/reverse_engineering/pages/playlist_page.dart`) fetches the playlist page HTML, and if that page has no videos it falls back to the browse API, with this comment in the code:

> "Fallback: fetch via the browse API. Needed for Mixes and YT Music playlists whose initial HTML page doesn't embed the video list."

The library authors explicitly built the Mix path. So `playlists.getVideos('RDAMVM<videoId>')` should return the Mix's tracks as a paged stream (about 25 per page, with continuations for more). **This still needs a live verification before relying on it** — a 5-minute check when implementing (see section 11). If the browse fallback ever fails for Mixes, the backup is the Innertube `next` endpoint with the playlist ID, which is exactly how yt-dlp fetches mixes — but that would be new code in Unbound, not a library call.

### What a Mix does not solve

A Mix is still YouTube's ordering, not Spotify's ratio. It will contain the seed artist, similar artists, and some newer artists — but not in a controlled ratio, and it can still include covers and live versions. That is why the Mix is the **source**, and the ratio shaping (section 6) is still needed on top of it. The Mix gets you much closer to the right pool; shaping gets you the ratio.

## 4. Finding 2: youtube_music_explode_dart — useful for caliber signals, NOT for radio

### What it is

Musify vendors a small local package, `packages/youtube_music_explode_dart` (~779 lines), that queries YouTube Music's `WEB_REMIX` browse/search endpoints. It was added in Musify PR #869 (June 2026) for artist pages. It is **not on pub.dev** as a standalone package — it only exists inside Musify's repo.

### What it actually offers

From reading the source (`packages/youtube_music_explode_dart/lib/src/music_client.dart`):

- `searchArtists(query)` — artist search.
- `searchSong(query, {expectedArtist, expectedTitle})` — music search, returns a `Video`.
- `getArtistProfile(channelId)` — returns a `MusicArtistProfile` with:
  - `monthlyListeners` — a string like `"331M monthly audience"`, exactly as YouTube Music displays it.
  - `topSongs` — the artist's Top Songs shelf.
  - `releases` — full discography (albums, singles, EPs).
  - `relatedArtists` — the **"Fans might also like"** shelf: artists YouTube Music itself considers similar.
- `getAlbum(albumBrowseId)` — album tracks.

### What it does NOT offer

**There is no radio function in it at all.** A search for "radio" across the whole package returns nothing. Musify does not use it for radio either — Musify's radio is hardcoded internet radio streams plus related videos (`common_services.dart`: `getRelatedVideos`, top 8 per seed, scored by position; and a "first related song not already played" refill). So adopting this library would **not** directly give Unbound a better radio.

### What it WOULD give Unbound

Two signals that matter for the ratio:

1. **`monthlyListeners` — the caliber signal.** This is artist-level popularity straight from YouTube Music ("331M monthly audience"). It is a far better "established vs emerging" signal than any video-level number, because it measures the artist, not one video. One call per distinct artist, and the result can be cached.
2. **`relatedArtists` ("Fans might also like") — the similar-artist signal.** This is YouTube Music's own curated similar-artist list for the seed artist. It answers "artists of the same caliber" directly, without guessing from video data.

### What adopting it costs

- It is not a pub.dev dependency. Unbound would either vendor Musify's local package — **which Daniel has explicitly rejected** (vendoring Musify's library would make Unbound "Musify with a different name") — or write its own small YouTube Music client in Unbound's own code, following the same public endpoint pattern (WEB_REMIX browse/search, ~a few hundred lines). There is also `dart_ytmusic_api` on pub.dev (unofficial YouTube Music API for Dart, updated 2026-06-02) as a third-party alternative, but it is a separate maintainer's package with its own breakage surface.
- Either way it is a **second Innertube surface** to maintain: when YouTube changes its Music endpoints, this breaks independently of `youtube_explode_dart`. Same class of fragility, twice the surface.
- Cost per use is low at runtime (one browse call per artist profile), but it is a real dependency decision, not a free signal.

**Verdict:** do not adopt it for radio itself. Consider it later, only for the caliber signal, if the view-count-free shaping (section 6) proves too blunt. Phase 1 of the radio work does not need it.

## 5. Finding 3: view count is a broken signal in the stock library — the honest catch

This is the finding that changes the plan. The parent task assumed view count could distinguish "established" from "emerging." The library says otherwise.

### What the data has

`Video.engagement` (`lib/src/common/engagement.dart`) has `viewCount` (int, always present), `likeCount` (int?, often null), `dislikeCount` (int?, often null).

### How related videos parse it — and why it is wrong

In `related_videos_client.dart`, both parsers (`_parseCompactVideo` and `_parseLockupView`) do this:

```dart
final views = int.tryParse(viewCountText?.stripNonDigits() ?? '') ?? 0;
```

`stripNonDigits()` removes everything that is not a digit. There is **no magnitude handling**. So:

| What YouTube shows | What the library records | True count |
|---|---|---|
| `1,234,567 views` | 1234567 | 1,234,567 ✓ |
| `1.2M views` | **12** | 1,200,000 ✗ |
| `845K views` | **845** | 845,000 ✗ |
| `3.4B views` | **34** | 3,400,000,000 ✗ |

A 1.2M-view video records as **12**. An 845K-view video records as **845**. So a video with 1.2 million views looks *less* popular than one with 845 thousand. The ordering is destroyed, not just noisy.

The library even contains a correct magnitude-aware parser — `parseViewCount()` in `helpers_extension.dart` ("Parse view count from a string formatted as an integer and its magnitude. Example: 5 views, 1.5K views, 2.3M views, 3.4B views.") — but **it is never called anywhere in the library**. The related-videos path does not use it. And Unbound cannot fix this from the `Video` object, because by the time `_toTrack()` sees the video, the raw text is already gone — only the mangled integer survives.

### What this means for the plan

- **Do not rank radio candidates by `engagement.viewCount` from related videos.** It is not a usable popularity signal as the library delivers it.
- The `Track` model still benefits from carrying a view count (it is real data when YouTube shows full numbers, and the watch-page path parses full numbers correctly), but it must be treated as a **rough band, not a ranking** — and the code must say so.
- The reliable "established vs emerging" signals are, in order: (1) artist `monthlyListeners` from YouTube Music (one call per artist, correct numbers); (2) the seed artist's own "Fans might also like" list; (3) YouTube's own related-videos **order** (which already encodes relevance and popularity, even if the numbers are mangled); (4) the user's own library (liked/recent) as the personal layer.
- There is a more expensive workaround: fetch the full video page per candidate (`_yt.videos.get(id)`), whose view count is a full number. That is one extra network call per candidate — 20 extra calls for a 20-track batch. Not worth it for radio shaping; the artist-level signal is cheaper and better.

## 6. Finding 4: the signals that actually work for shaping the ratio

Given the view-count catch, here is what can shape the mix, from strongest to weakest:

### A. Artist identity (free, always available)
Every `Video` has `author` and `channelId`. The seed artist is known (the radio seed). A candidate is "seed artist" if its author/channel matches the seed. This alone gives bucket (a) of the ratio. It also powers the remix filter: a candidate whose title contains "remix," "cover," "sped up," "slowed," "8D," or "nightcore" gets downranked or dropped, and `Video.isLive` filters live streams. These are cheap string checks on data already in hand.

### B. YouTube's own related-videos order (free, already fetched)
The order YouTube returns related videos in already encodes relevance and popularity — YouTube put the most relevant first. So "take the top N, then arrange" is a reasonable base. The shaping does not need to re-rank from scratch; it needs to **interleave** (never two in a row from the same non-seed artist, keep the seed artist present throughout, reserve slots for the long tail).

### C. The Mix as the pool (free, one call)
The RDAMVM Mix (section 3) is a better pool than raw related videos because YouTube Music already filtered it to music. Shaping the Mix's order is easier than shaping raw related videos because the pool is cleaner.

### D. Artist monthlyListeners (one call per distinct artist, best caliber signal)
From a YouTube Music artist profile. Correct numbers, artist-level, directly answers "same caliber vs emerging." Costs a small client (section 4) and one browse call per artist — so cache it per artist, and only fetch it for the handful of distinct artists in a radio batch, not per track.

### E. "Fans might also like" (same call as D)
The seed artist's related-artists shelf. Any candidate whose artist is on that shelf is by definition "same caliber" in YouTube Music's own judgment. This is the cleanest "similar artists" signal available without building anything.

### F. The user's own library (free, local, personal)
Unbound already has liked songs and recently played, locally. Spotify's radio is personalized; Unbound's can be too, cheaply: when building a radio queue, sprinkle in liked/recent tracks whose artist appears in the related-artists set or the Mix. This is the "your taste" layer, and it costs no network at all. Musify's recommendations already do a version of this (own mix = liked + recent + playlists, shuffled).

### G. Multi-seed related videos (free, a few extra calls)
Instead of seeding related videos from only the current track, seed from 2–3 recent tracks (the way Musify's `getExternalRecommendations` already does: 5 most recent seeds, top 8 each, scored by position × recency). A broader seed set gives a broader, less repetitive pool — closer to Spotify's variety.

## 7. The recommendation (the combination)

**Use the Mix as the source, shape the ratio in Unbound's own code, and add the personal layer. Do not adopt the music library in phase 1.**

Concretely, in order:

1. **Source: RDAMVM Mix first.** `playlists.getVideos('RDAMVM<seedVideoId>')` gives ~25 music-focused tracks per page, with continuations. This replaces raw related videos as the primary radio pool. It is YouTube Music's radio, not YouTube's watch-next list.
2. **Seed properly.** A Mix needs a seed *video*, not just an artist name. From a track (search result, Now Playing), the seed video is that track. From an artist name (Radio tab), resolve a seed track first — search the artist and take the first result, or the artist's top song. This is one extra search call for the typed-artist path.
3. **Shape the mix.** Bucket the Mix's tracks into (a) seed artist (author/channel match), (b) other artists, (c) long-tail/emerging (the back half of the Mix's order, plus any track whose artist has low monthlyListeners if that signal is available). Interleave to roughly equal thirds, never two in a row from the same non-seed artist, dedupe by video ID. Filter remixes/covers/live by title and `isLive`.
4. **Add the personal layer.** Sprinkle in 2–3 liked/recent tracks whose artist is in the radio's artist set. This is what makes the radio feel like *Daniel's* radio rather than a generic mix.
5. **Keep the fallbacks.** If the Mix fetch fails, fall back to related videos of the current track (current behaviour). If that fails, fall back to `fetchArtistRadioTracks` (search-based). The radio never dies because one source failed.
6. **Defer the music client.** Do not adopt `youtube_music_explode_dart` (or a home-grown equivalent) in phase 1. The Mix + shaping + personal layer gets most of the way there. Add the artist-profile caliber signal later only if the ratio still feels wrong — it is a clean second phase, and by then the shaping code will already have a place to plug the signal in.

## 8. Concrete implementation steps (Unbound's own code)

No code was written for this dive. These are the changes, in order:

### Step 1 — Carry a popularity signal in the Track model
- **File:** `lib/models/track.dart`
- Add `final int? viewCount;` to `Track`, with `this.viewCount` in the constructor, and include it in `fromJson`/`toJson`. Note: because `Track` is the shared model with the web app (`src/types.ts`), the web type should gain the same optional field, or the APK-only mapper should tolerate its absence. Document the mangling caveat in the field comment: view counts from related videos may be abbreviated-collapsed (1.2M → 12) and must be treated as a rough band, never a ranking.

### Step 2 — Fetch the Mix
- **File:** `lib/services/youtube_service.dart`
- Add `fetchMixTracks(String videoId)`: `final id = 'RDAMVM$videoId';` then `await _yt.playlists.getVideos(id).take(25).toList()` mapped through `_toTrack` (now carrying viewCount). Wrap in try/catch returning `[]` on failure — the caller falls back.
- Modify `_toTrack` to pass `viewCount: video.engagement.viewCount` through.

### Step 3 — Shape the mix
- **File:** `lib/services/youtube_service.dart` (new function, e.g. `shapeRadioMix`)
- Inputs: a candidate list (from the Mix, or related videos as fallback), the seed artist name, the seed artist channelId, and optionally a set of the user's liked/recent artist names.
- Logic, in plain terms:
  - Dedupe by video ID.
  - Drop live streams (`isLive`) and downrank/drop titles matching remix/cover/sped-up/slowed/8D/nightcore.
  - Bucket A: author or channelId matches the seed artist.
  - Bucket B: every other artist.
  - Bucket C (emerging): the back half of the candidate order — or, when monthlyListeners is available later, artists below a threshold.
  - Interleave A, B, C in roughly equal thirds; never place two B tracks from the same artist back to back.
  - Sprinkle in up to 3 liked/recent tracks whose artist is in bucket B.
  - Return the arranged list (aim for 20–25 tracks).
- This is pure selection/arrangement logic — no network, no new engine, trivially testable.

### Step 4 — Wire the Mix into radio start and refill
- **File:** `lib/services/audio_handler.dart`
- `startRadio(artist)`: resolve a seed track for the artist (search, first result), then `fetchMixTracks(seedVideoId)`, shape it, and use that as the queue. Fall back to `fetchArtistRadioTracks` if the Mix is empty.
- `_maybeRefill()`: keep the within-5-of-the-end trigger. Refill from the Mix continuation if available, otherwise related videos of the current track, shaped the same way. The refill already appends fresh tracks; the only change is *which* tracks it appends (shaped Mix/related instead of raw related order).

### Step 5 — Add "go to artist radio" where Daniel actually finds music
- **File:** `lib/screens/screens.dart` (search results + Now Playing)
- Add a "Start artist radio" action on a search result (long-press menu, or a small radio icon on the track row) and on the Now Playing card. It seeds from that track: `startRadio` with the track's artist, using the track itself as the Mix seed video. This is the Spotify entry point Daniel described — it appears when you dig into a result, not only in the Radio tab. The Radio tab's type-an-artist field stays as the manual path.

### Step 6 (phase 2, only if the ratio still feels wrong) — artist caliber signal
- **New file:** `lib/services/music_client.dart` (Unbound's own minimal YouTube Music client — do NOT vendor Musify's package)
- Implement only what is needed: `getArtistProfile(channelId)` returning monthlyListeners (parsed to a number from strings like "331M monthly audience") and the "Fans might also like" artist list. Alternatively evaluate `dart_ytmusic_api` from pub.dev for the same two calls.
- Use it to classify bucket B vs bucket C properly (same-caliber vs emerging) instead of the order-based heuristic. Cache profiles per artist in `StorageService` so a repeat radio for the same artist costs no network.
- This is deliberately phase 2: it adds a second Innertube surface, and the phase-1 Mix + shaping may already feel right.

## 9. Refill strategy: big batch up front, keep refilling within 5 of the end

**Keep the refill-within-5 behaviour — it is the right design — and pull a bigger initial batch.**

- **Initial batch:** pull 20–25 tracks up front (one Mix page). This matters because the first screen of radio is what Daniel judges: a full queue that already shows the ratio is more convincing than a queue that grows one track at a time.
- **Refill:** keep the current trigger (within 5 of the end). Refilling late is better than pulling everything up front, because (a) it adapts to what Daniel actually listened to in this session (the refill seeds from the *current* track, so the radio drifts with his taste as the session goes on), and (b) it does not waste network on tracks he will never reach. The current `_maybeRefill` already does this; the change is only what it appends (shaped Mix/related instead of raw related order).
- **Do not** switch to "pull 100 tracks up front." It wastes network, the back half goes stale, and it freezes the radio's taste at the seed instead of letting it evolve. Spotify's radio also refills continuously rather than precomputing a giant list.

## 10. Honest limitations — what Spotify does that no YouTube approach can match

1. **Audio similarity.** Spotify knows how a track *sounds* (tempo, key, energy, mood, danceability) and matches on sound. YouTube knows what people *watch next*. If two artists sound alike but their YouTube audiences do not overlap, YouTube will not connect them, and no amount of shaping fixes that. The Mix is the closest proxy because YouTube Music's engine does use audio features — but Unbound cannot see them or tune them.
2. **Collaborative filtering at scale.** Spotify knows what millions of listeners with similar taste play next. YouTube's related videos are a form of this, but they are optimized for watch time, not for musical taste — which is why a related list can include a vlog or a reaction video next to a song. The Mix filters to music, but the underlying optimization is still engagement.
3. **A real similarity score.** Spotify can say "artist X is 0.87 similar to artist Y." YouTube exposes no similarity score. Unbound's buckets are heuristics: name match, list membership, order position, view bands. The ratio can be approximated, never guaranteed. Some mixes will feel off, and the only fix is a different seed.
4. **Emerging-artist discovery.** Spotify's new-music pipeline (editorial + Release Radar + Discover Weekly data) deliberately surfaces breaking artists. YouTube surfaces emerging artists through view counts and channel growth, which is noisier and slower — a great new artist with 3,000 views looks the same as a mediocre one. The monthlyListeners signal helps, but it lags: an artist has to already be breaking for the number to show it.
5. **Personal taste profile.** Spotify's radio is different for every listener because it knows years of listening history. Unbound's personal layer is only liked songs and recent plays on this device. That is a genuine but much thinner taste signal. It helps; it does not replicate a profile.
6. **The Mix is still the grey lane.** RDAMVM fetching goes through the same Innertube endpoints as everything else in the APK. If YouTube changes its Mix format or restricts it, the radio source breaks the same way stream extraction can. The fallbacks (related videos, then search) are what keep radio working when that happens.
7. **A Mix needs a seed video.** Spotify seeds radio from an artist entity. A Mix seeds from a video ID. For the typed-artist path, Unbound must resolve an artist name to a seed track first (one search call). That is a small extra step and a small extra failure mode.

None of these is a reason not to do it. They are the reason to promise "much closer to Spotify's feel" and not "Spotify's radio."

## 11. What to verify first (before building)

Three quick checks, in order, before writing any of the code in section 8:

1. **Does `playlists.getVideos('RDAMVM<videoId>')` return tracks?** Use a known video (e.g. Joyner Lucas "Seventeen", `TLAuRp3xFTE` → `RDAMVMTLAuRp3xFTE`). If it returns ~25 music tracks, the Mix path is real. If it returns nothing or errors, the Mix must be fetched via the Innertube `next` endpoint instead (the yt-dlp route) — a bigger change.
2. **Is the Mix actually music-only?** Eyeball the first 25 tracks: are they songs by real artists, or does it include vlogs, reactions, and live performances? If the Mix is clean, the remix/live filter in shaping can be light. If it is dirty, the filter has to be aggressive.
3. **Confirm the view-count mangling on a real related-videos fetch.** Pull related videos for a popular track and look at the recorded `engagement.viewCount` values: if a video YouTube shows as "1.2M views" records as 12, the mangling is confirmed live and the "never rank by view count" rule is settled.

## 12. Verification log — 2026-11-14 (live checks run, results)

Ran 2026-11-14 ~07:00 MST from this workspace, using the project's own
`youtube_explode_dart` 3.1.0 via a throwaway Dart script
(`docs/artist-radio-mix-check.dart`, runnable with the project's
`.dart_tool/package_config.json`). Seed video: Joyner Lucas "Seventeen",
`TLAuRp3xFTE`.

### Check 1 — Mix via `playlists.getVideos('RDAMVM…')`: INCONCLUSIVE here, not failed

- `RDAMVMTLAuRp3xFTE` → **0 tracks**. `RDTLAuRp3xFTE` (regular Mix) → 0.
  A second seed (`RDAMVMdQw4w9WgXcQ`) → 0. Metadata via `playlists.get()`
  also came back empty (title "", count null).
- **Control test:** a normal user playlist found by search
  ("Best of Joyner Lucas", `PL5YfILI0mbyAR4ffEx-vyzpgzyCa-0deS`, 37 videos)
  also returned **0 tracks** via the same `getVideos` call in this
  environment. So playlist fetching as a whole returns empty here — the
  failure is not specific to Mixes.
- Likely cause: `PlaylistPage.get()` falls back to a POST to YouTube's
  `browse` endpoint for playlists whose HTML embeds no video list, and that
  request appears to be blocked in this sandbox (the run reported an egress
  restriction on the playlist calls, while watch-page/search GETs worked).
  **Do not conclude the Mix path is broken, and do not build on the
  assumption it works.** It still needs a live check on a real network —
  either from Daniel's phone in a debug build, or from an unrestricted
  machine. If it still returns 0 there, the fallback is the Innertube
  `next` endpoint with the playlist ID (the yt-dlp route), which is a
  bigger change than a library call.

### Check 2 — Is the Mix music-only: NOT YET CHECKABLE

No Mix tracks were returned, so there was nothing to eyeball. Stays open
until check 1 passes on a real network.

### Check 3 — View-count mangling: CONFIRMED LIVE, worse than expected

`videos.getRelatedVideos` for "Seventeen" returned 17 related videos.
**All 15 inspected recorded `engagement.viewCount` under 1,000** — e.g.
Joyner Lucas "24 hours to live" (official video) → 21, Kodak Black
"These Streets" → 15, Eminem "Tobey" → 69, J. Cole lyrics video → 37.
These are plainly multi-million-view videos; the library is recording the
digits of the abbreviated display ("2.1M" → 21) exactly as section 5
predicted. Source-code check confirmed at the same time: both parsers in
`related_videos_client.dart` (lines 45, 82) do
`int.tryParse(viewCountText?.stripNonDigits() ?? '')`, and the correct
`parseViewCount()` in `helpers_extension.dart` is never called anywhere in
the library. **Rule settled: never rank radio candidates by view count
from related videos.**

### Bonus finding — the related-videos pool is polluted with non-music

The same 17 related videos included a "Cats | Animation 2020" video, a
Jimmy Kimmel Live political segment, and a Club Shay Shay podcast
interview — alongside the music. That is direct evidence related videos
optimize for watch time, not music similarity, and it means any radio
built on related videos needs a music-only filter (title/channel
heuristics, `isLive` exclusion) even as a fallback — not just the
remix/cover filter in section 6.

### Revised implication for the plan

- The Mix remains the best *hypothesis* for the radio source, but it is
  unverified, so phase 1 should be built to work **without** it first:
  shaped related videos (with the music-only filter) as the working
  source, with the Mix plugged in behind the same `shapeRadioMix` once
  check 1 passes on a real network. That way the wow build is not blocked
  on a network check nobody can run from here.
- The shaping plan (section 6/7) is unchanged and now more important:
  artist identity, YouTube's order, and the personal layer are the only
  signals verified usable.

### Browser check — 2026-11-15 evening (live browser, read-only, no sign-in)

Daniel chose "Wait for the Mix check first" (2026-11-15 ~18:12 MST), so
the wow build waits on this check. A live browser task verified the Mix
`RDAMVMTLAuRp3xFTE` (Joyner Lucas "Seventeen", `TLAuRp3xFTE`):

- **YouTube Music** (`music.youtube.com/watch?v=TLAuRp3xFTE&list=RDAMVM...`):
  page loads, no sign-in prompt, no error. Player shows "Seventeen
  (Instrumental)" by Joyner Lucas with an "Up next" tab — but the
  queue/track list never rendered in the browser. So YouTube Music
  confirms the Mix exists and loads, but the track list could not be
  read there.
- **Regular YouTube** (`youtube.com/watch?v=TLAuRp3xFTE&list=RDAMVM...`):
  loads fully, shows the complete Mix playlist. Heading "Mix - Joyner
  Lucas - Seventeen 'Official Music Video' (Not Now I'm Busy)", note
  "Mixes are playlists YouTube makes for you", loop/shuffle controls,
  full track list below.
- **Check 2 — music-only: VERIFIED.** All 25 tracks in the first page
  are music videos, lyric videos, or remixes by recording artists. No
  vlogs, reaction videos, podcasts, comedy, animation, or live talk
  segments.
- **New finding — the Mix is heavily seed-weighted.** 22 of the 25
  tracks are Joyner Lucas or collaborations featuring him. Only two
  tracks are fully by other artists (Jack Harlow, Machine Gun Kelly),
  plus one E-40 track featuring Joyner Lucas & T.I. So the Mix alone
  does NOT deliver Spotify's equal ratio — it is a clean music-only
  pool, heavily weighted to the seed artist. The ratio shaping in
  section 6/7 is essential, not optional: without it, radio would be
  ~90% the seed artist. This validates the `shapeRadioMix` plan.
- **Remixes are in the Mix too.** The first 25 include Bank Account
  (Remix), Will (Remix), Look Alive (Remix), What's Poppin Remix, and
  Suge (Remix) — so the remix/cover filter is needed even with the Mix
  as the source, not just for related videos.
- **Check 1 — the library call: STILL UNVERIFIED.** The browser proves
  the Mix exists, is populated, and is music-only. It cannot prove
  `playlists.getVideos('RDAMVM...')` returns tracks in the app — that
  needs a real network (Daniel's phone). The sandbox failure (section
  12, 2026-11-14) was proven environmental (control playlist also 0),
  and the library has an explicit Mix browse fallback, so the call is
  likely to work — but "likely" is not verified. The remaining test
  needs Daniel's phone; the smallest form is an open question (a tiny
  test build vs the wow build proving it with fallbacks in place).

## Sources (in order of authority)

1. **youtube_explode_dart 3.1.0 source (local pub cache)** — `lib/src/reverse_engineering/pages/playlist_page.dart` (Mix browse fallback, quoted in section 3); `lib/src/reverse_engineering/clients/related_videos_client.dart` (view-count parsing with no magnitude handling, section 5); `lib/src/common/engagement.dart` (Engagement fields); `lib/src/videos/video.dart` (Video fields incl. `isLive`, `musicData`, `channelId`); `lib/src/extensions/helpers_extension.dart` (`parseViewCount()` exists but is never called); `lib/src/playlists/playlist_client.dart` (`getVideos` paging).
2. **Musify, public repo (cloned 2026-11-13, commit `83fe47e`)** — `packages/youtube_music_explode_dart/lib/src/music_client.dart` (no radio function; `getArtistProfile` with `monthlyListeners` and `relatedArtists`); `lib/services/common_services.dart` (related-videos recommendations, top 8 per seed; "first related song not in queue" refill); `lib/services/audio_service.dart` (radio = hardcoded internet streams + related videos). Mechanism reference only — no code copied, and the vendored music library is **not** recommended for adoption (section 4).
3. **NewPipe Extractor docs** — `YoutubeParsingHelper`: "Ids from a YouTube Music Mix start with `RDAMVM` or `RDCLAK`"; genre mix `RDGMEM`; My Mix `RDMM`. https://teamnewpipe.github.io/NewPipeExtractor/javadoc/org/schabi/newpipe/extractor/services/youtube/YoutubeParsingHelper.html
4. **Archiveteam, YouTube/Technical details** — playlist ID table: `RD<videoID>` Mix, `RDAMVM<videoID>` Mix ("Unviewable, playnext and watch functional"), `RDMM` My Mix. https://wiki.archiveteam.org/index.php/YouTube/Technical_details
5. **DeepWiki, bedrock-api YouTube provider** — RDAMVM radio flow, "YouTube Music's recommendation engine," and the RD vs RDAMVM distinction (music-focused vs non-music content). https://deepwiki.com/feralbureau/bedrock-api/5.1-youtube-provider
6. **DeepWiki, Beatbump download system** — `songMixNext` calls `yt_api.Next(videoID, "RDAMVM"+videoID, …)` to fetch the next batch of related tracks. https://deepwiki.com/giwty/Beatbump/5-download-system
7. **Musify PR #869** — "Adds a separate local `youtube_music_explode_dart` package for the small YouTube Music API surface used by Musify." https://github.com/gokadzev/Musify/pull/869
8. **Google, YouTube Music Help** — personal/custom mixes, "Start Radio" from a song. https://support.google.com/youtubemusic/answer/15165061?hl=en
9. **Unbound's own code (verified 2026-11-13)** — `lib/services/youtube_service.dart` (`fetchRelatedTracks`, `fetchArtistRadioTracks`, `_toTrack`), `lib/services/audio_handler.dart` (`_maybeRefill`, `_pullOneMoreRelated`, `startRadio`), `lib/screens/screens.dart` (Radio tab), `lib/models/track.dart` (Track, no viewCount), `lib/services/recommendations.dart` (own mix vs external related-videos recommendations).
