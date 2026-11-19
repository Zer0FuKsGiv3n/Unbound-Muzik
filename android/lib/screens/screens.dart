// Unbound Muzik — the five screens. Five tabs only: Home, Search,
// Library, Queue, Radio. Everything else folds into those.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/track.dart';
import '../services/audio_handler.dart';
import '../services/cover_art.dart';
import '../theme/unbound_theme.dart';
import '../widgets/widgets.dart';

/// Wordmark shown at the top of every tab.
Widget _wordmark(PlaybackUiState playback) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(
          text: TextSpan(
            style: UnboundTheme.dark().textTheme.displayLarge,
            children: [
              const TextSpan(text: 'Unbound '),
              TextSpan(
                text: 'Muzik',
                style: TextStyle(
                  foreground: Paint()
                    ..shader = UnboundColors.gradient.createShader(
                      const Rect.fromLTWH(0, 0, 200, 40),
                    ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Muzik, unbound from the ridiculousness.',
          style: TextStyle(color: UnboundColors.textDim),
        ),
        const SizedBox(height: 12),
        PlayingPill(
          statusText: playback.statusText,
          playing: playback.isPlaying,
        ),
      ],
    ),
  );
}

Widget _errorBox(String message, VoidCallback onDismiss) {
  return Container(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0x1FFF5050),
      border: Border.all(color: const Color(0x59FF5050)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Expanded(child: Text(message)),
        IconButton(
          onPressed: onDismiss,
          icon: const Icon(Icons.close, size: 18),
          tooltip: 'Dismiss',
        ),
      ],
    ),
  );
}

Widget _finishedBox() {
  return Container(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0x1A34D399),
      border: Border.all(color: const Color(0x5934D399)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Text(
      'Queue finished. Tap ▶ to play it again from the start.',
    ),
  );
}

Widget _noticeBox(String message, VoidCallback onDismiss) {
  return Container(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: UnboundColors.ink,
      border: Border.all(color: UnboundColors.glassBorder),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Expanded(child: Text(message)),
        IconButton(
          onPressed: onDismiss,
          icon: const Icon(Icons.close, size: 18),
          tooltip: 'Dismiss',
        ),
      ],
    ),
  );
}

/// Shared list body: error, finished state, notice, then the tab content.
Widget _tabBody({
  required AppState state,
  required List<Widget> children,
}) {
  final playback = state.playback;
  return ListView(
    padding: const EdgeInsets.only(bottom: 24),
    children: [
      _wordmark(playback),
      if (playback.errorMessage != null)
        _errorBox(
          playback.errorMessage!,
          state.handler.dismissError,
        ),
      if (playback.queueEnded) _finishedBox(),
      if (state.notice != null)
        _noticeBox(state.notice!, state.dismissNotice),
      ...children,
    ],
  );
}

TrackRow _row(AppState state, Track track, List<Track> list) {
  final playback = state.playback;
  final index = list.indexOf(track);
  return TrackRow(
    track: track,
    isCurrent: playback.currentTrack?.id == track.id && list == playback.queue,
    isPlaying: playback.isPlaying,
    isLiked: state.isLiked(track),
    onTap: () => state.handler.playAt(index, list: list),
    onLike: () => state.toggleLike(track),
  );
}

// --- Home ---

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final playback = state.playback;
    final current = playback.currentTrack;
    return _tabBody(
      state: state,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GlassPanel(
            child: current == null
                ? const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Nothing playing yet',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Search for a song, start a radio station, or pick a recommendation below.',
                        style: TextStyle(color: UnboundColors.textDim),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      TrackCover(
                        thumb: current.thumb,
                        seed: current.id + current.title,
                        title: current.title,
                        size: 88,
                        borderRadius: 14,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              current.title,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              current.artist,
                              style: const TextStyle(
                                color: UnboundColors.textDim,
                              ),
                            ),
                            const SizedBox(height: 8),
                            EqBars(playing: playback.isPlaying, height: 20),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Recommended for you',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              TextButton(
                onPressed:
                    state.recsLoading ? null : state.loadRecommendations,
                child: Text(
                  state.recsLoading ? 'Refreshing…' : 'Refresh',
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: state.externalRecs,
                activeColor: UnboundColors.violet,
                onChanged: (v) {
                  if (v != null) state.toggleExternalRecs(v);
                },
              ),
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'External recommendations — expand picks from YouTube related videos. Off means your own mix only: liked, recent, and playlists. No network.',
                    style: TextStyle(color: UnboundColors.textDim),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (state.recommendations.isEmpty && !state.recsLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Nothing to recommend yet — like a song or play one, and recommendations will appear here.',
              style: TextStyle(color: UnboundColors.textDim),
            ),
          ),
        if (state.recsLoading && state.recommendations.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Finding recommendations…',
              style: TextStyle(color: UnboundColors.textDim),
            ),
          ),
        ...state.recommendations.map(
          (t) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _row(state, t, state.recommendations),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 32),
          child: Center(
            child: Text(
              'Unbound is free forever. No ads from the app, no tracking, no account.',
              textAlign: TextAlign.center,
              style: TextStyle(color: UnboundColors.textFaint, fontSize: 13),
            ),
          ),
        ),
      ],
    );
  }
}

// --- Search ---

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.state});

  final AppState state;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final searchState = state.searchState;
    return _tabBody(
      state: state,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Search',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        hintText: 'Song, artist, album…',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                        ),
                        filled: true,
                        fillColor: UnboundColors.ink,
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (q) => state.handleSearch(q),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => state.handleSearch(_controller.text),
                    style: FilledButton.styleFrom(
                      backgroundColor: UnboundColors.violet,
                      minimumSize: const Size(64, 48),
                    ),
                    child: const Text('Search'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (searchState is SearchIdle)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'One box, no source to pick. When you search, it is instantly there or it is not.',
              style: TextStyle(color: UnboundColors.textDim),
            ),
          ),
        if (searchState is SearchLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Searching…',
              style: TextStyle(color: UnboundColors.textDim),
            ),
          ),
        if (searchState is SearchError)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              searchState.message,
              style: const TextStyle(color: Color(0xFFFF8080)),
            ),
          ),
        if (searchState is SearchEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Nothing found for “${searchState.query}”. Try different words.',
              style: const TextStyle(color: UnboundColors.textDim),
            ),
          ),
        if (searchState is SearchReady)
          ...searchState.tracks.map(
            (t) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _row(
                state,
                t,
                searchState.tracks,
              ),
            ),
          ),
      ],
    );
  }
}

// --- Library ---

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.state});

  final AppState state;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<({Track track, String path})>? _downloads;
  bool _loadingDownloads = false;

  @override
  void initState() {
    super.initState();
    _refreshDownloads();
  }

  Future<void> _refreshDownloads() async {
    if (_loadingDownloads) return;
    _loadingDownloads = true;
    final pairs = await widget.state.downloads
        .downloadedTracks(widget.state.trackCache);
    if (!mounted) return;
    setState(() {
      _downloads = pairs
          .map((p) => (track: p.track, path: p.file.path))
          .toList();
      _loadingDownloads = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return _tabBody(
      state: state,
      children: [
        _sectionTitle('Liked songs'),
        if (state.liked.isEmpty)
          const _Hint('No liked songs yet — tap ♡ Like on any song.')
        else
          ...state.liked.map(
            (t) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _row(state, t, state.liked),
            ),
          ),
        _sectionTitle('Recently played'),
        if (state.recentlyPlayed.isEmpty)
          const _Hint(
            'Nothing played yet — your real listening history will show here.',
          )
        else
          ...state.recentlyPlayed.map(
            (t) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _row(state, t, state.recentlyPlayed),
            ),
          ),
        _sectionTitle('Playlists'),
        if (state.playlists.isEmpty)
          const _Hint(
            'No playlists yet — save the current queue as a playlist from the Queue tab.',
          )
        else
          ...state.playlists.map(
            (p) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => state.playPlaylist(p),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              '${p.trackIds.length} songs',
                              style: const TextStyle(
                                color: UnboundColors.textDim,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => state.deletePlaylist(p.id),
                    child: const Text(
                      'Delete',
                      style: TextStyle(color: UnboundColors.textDim),
                    ),
                  ),
                ],
              ),
            ),
          ),
        _sectionTitle('Downloads'),
        if (_loadingDownloads)
          const _Hint('Checking downloaded files…')
        else if (_downloads == null || _downloads!.isEmpty)
          const _Hint(
            'No downloaded files yet. Downloads are real files stored on this phone — tap the download button on a song in the Queue to save it. Nothing here pretends to be a download.',
          )
        else
          ..._downloads!.map(
            (d) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      // The handler checks for a downloaded file first,
                      // so this plays the real file, not a stream.
                      onTap: () => state.handler.playAt(0, list: [d.track]),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            TrackCover(
                              thumb: d.track.thumb,
                              seed: d.track.id + d.track.title,
                              title: d.track.title,
                              size: 48,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    d.track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const Text(
                                    'Saved on this phone',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: UnboundColors.textDim,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await state.deleteDownload(d.track);
                      _refreshDownloads();
                    },
                    child: const Text(
                      'Delete',
                      style: TextStyle(color: UnboundColors.textDim),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

Widget _sectionTitle(String title) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      title,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
    ),
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        text,
        style: const TextStyle(color: UnboundColors.textDim),
      ),
    );
  }
}

// --- Queue ---

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key, required this.state});

  final AppState state;

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final playback = state.playback;
    return _tabBody(
      state: state,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Queue',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              OutlinedButton(
                onPressed: state.toggleRepeat,
                child: Text('Repeat: ${state.repeatOn ? 'On' : 'Off'}'),
              ),
            ],
          ),
        ),
        if (playback.radioSeed != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Radio station: ${playback.radioSeed} — new songs are added as you get near the end.',
              style: const TextStyle(color: UnboundColors.textDim),
            ),
          ),
        if (playback.queue.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'The queue is empty. Search for a song or start a radio station to fill it.',
              style: TextStyle(color: UnboundColors.textDim),
            ),
          )
        else
          ...playback.queue.asMap().entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TrackRow(
                track: entry.value,
                isCurrent: entry.key == playback.currentIndex,
                isPlaying: playback.isPlaying,
                isLiked: state.isLiked(entry.value),
                onTap: () => state.handler.playAt(entry.key),
                onLike: () => state.toggleLike(entry.value),
                trailing: IconButton(
                  onPressed: () async {
                    await state.downloadTrack(entry.value);
                  },
                  icon: const Icon(Icons.download, size: 20),
                  tooltip: 'Download this song as a real file',
                  color: UnboundColors.textDim,
                ),
              ),
            ),
          ),
        if (playback.queue.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      hintText: 'Name this playlist…',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                      ),
                      filled: true,
                      fillColor: UnboundColors.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {
                    state.saveQueueAsPlaylist(_nameController.text);
                    _nameController.clear();
                  },
                  child: const Text('Save queue'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// --- Radio ---

class RadioScreen extends StatefulWidget {
  const RadioScreen({super.key, required this.state});

  final AppState state;

  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen> {
  final _artistController = TextEditingController();

  @override
  void dispose() {
    _artistController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final playback = state.playback;
    return _tabBody(
      state: state,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Artist radio',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Pick an artist and keep listening. Radio is built from YouTube\'s own related-videos data here — the real "what\'s next" graph, not a search simulation.',
                style: TextStyle(color: UnboundColors.textDim),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _artistController,
                      decoration: const InputDecoration(
                        hintText: 'Artist name…',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                        ),
                        filled: true,
                        fillColor: UnboundColors.ink,
                      ),
                      textInputAction: TextInputAction.go,
                      onSubmitted: (a) => state.startRadio(a),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: state.radioLoading
                        ? null
                        : () => state.startRadio(_artistController.text),
                    style: FilledButton.styleFrom(
                      backgroundColor: UnboundColors.violet,
                      minimumSize: const Size(64, 48),
                    ),
                    child: Text(
                      state.radioLoading ? 'Starting…' : 'Start Radio',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: state.radioAutoPlay,
                    activeColor: UnboundColors.violet,
                    onChanged: (v) {
                      if (v != null) state.toggleRadioAutoPlay(v);
                    },
                  ),
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Keep playing after the queue ends — pull in one more related song instead of stopping. Off means the queue ends cleanly, the way the web app does.',
                        style: TextStyle(color: UnboundColors.textDim),
                      ),
                    ),
                  ),
                ],
              ),
              if (playback.radioSeed != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Now playing station: ${playback.radioSeed}',
                    style: const TextStyle(color: UnboundColors.textDim),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
