// Unbound Muzik — the full-screen Now Playing sheet.
//
// This is the expanded half of the persistent player sheet (item 1 of
// the elite roadmap). The sheet lives in HomeShell's body as a
// DraggableScrollableSheet; this widget is its content. The scroll
// controller handed to the sheet's builder MUST be passed to the
// CustomScrollView below — if it is ignored, the sheet stays at its
// minimum size and ignores drags.
//
// Layout, top to bottom:
//   - A fixed-height collapsed header (drag handle + PlayerBar). At the
//     sheet's minimum size only this is visible; tapping it (outside the
//     transport buttons) expands the sheet.
//   - The expanded Now Playing view: large artwork, title/artist, the
//     seek bar, and transport (like, previous, play/pause, next, repeat).
//   - The queue, as a scrollable list. Tapping a row plays that track.
//
// Sheet expanded/collapsed state is local UI state owned by HomeShell,
// never in PlaybackUiState. Position stays out of PlaybackUiState too —
// the seek bar subscribes directly to the handler's position stream.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../services/audio_handler.dart';
import '../services/cover_art.dart';
import '../theme/unbound_theme.dart';
import 'widgets.dart';

class NowPlayingSheet extends StatelessWidget {
  const NowPlayingSheet({
    super.key,
    required this.scrollController,
    required this.state,
    required this.miniPlayerHeight,
    required this.onExpand,
    required this.onCollapse,
  });

  final ScrollController scrollController;
  final AppState state;
  final double miniPlayerHeight;
  final VoidCallback onExpand;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final playback = state.playback;
    final track = playback.currentTrack;
    return Container(
      decoration: const BoxDecoration(
        color: UnboundColors.playerBar,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
          top: BorderSide(color: UnboundColors.glassBorder),
        ),
      ),
      child: CustomScrollView(
        controller: scrollController,
        slivers: [
          // Collapsed header: drag handle + PlayerBar, fixed height.
          // At the sheet's minimum size only this is visible.
          SliverToBoxAdapter(
            child: SizedBox(
              height: miniPlayerHeight,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: UnboundColors.textDim,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: onExpand,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                        child: PlayerBar(
                          track: track,
                          isPlaying: playback.isPlaying,
                          isStarting: playback.isStarting,
                          onToggle: () => state.handler.togglePlay(),
                          onNext: () => state.handler.skipToNext(),
                          onPrevious: () => state.handler.skipToPrevious(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Expanded Now Playing view.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: track == null
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Text(
                        'Nothing playing',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: UnboundColors.textDim,
                          fontSize: 16,
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Now Playing',
                              style: TextStyle(
                                color: UnboundColors.textDim,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            IconButton(
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                onCollapse();
                              },
                              icon: const Icon(Icons.keyboard_arrow_down),
                              tooltip: 'Collapse',
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TrackCover(
                          thumb: track.thumb,
                          seed: track.id + track.title,
                          title: track.title,
                          size: 280,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          track.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: UnboundColors.textDim,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 16),
                        StreamBuilder<PositionData>(
                          stream: state.handler.positionDataStream,
                          builder: (context, snapshot) {
                            final data = snapshot.data;
                            return SeekBar(
                              duration: data?.duration ?? Duration.zero,
                              position: data?.position ?? Duration.zero,
                              bufferedPosition:
                                  data?.bufferedPosition ?? Duration.zero,
                              onChangeEnd: (position) =>
                                  state.handler.seek(position),
                            );
                          },
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                state.toggleLike(track);
                              },
                              icon: Icon(
                                state.isLiked(track)
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: state.isLiked(track)
                                    ? UnboundColors.aquaBright
                                    : null,
                              ),
                              tooltip: 'Like',
                            ),
                            IconButton(
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                state.handler.skipToPrevious();
                              },
                              icon: const Icon(Icons.skip_previous),
                              iconSize: 36,
                              tooltip: 'Previous track',
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 72,
                              height: 72,
                              child: ElevatedButton(
                                onPressed: () {
                                  HapticFeedback.lightImpact();
                                  state.handler.togglePlay();
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: UnboundColors.aqua,
                                  foregroundColor: Colors.white,
                                  shape: const CircleBorder(),
                                  padding: EdgeInsets.zero,
                                ),
                                child: playback.isStarting
                                    ? const Text(
                                        '…',
                                        style: TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      )
                                    : Icon(
                                        playback.isPlaying
                                            ? Icons.pause
                                            : Icons.play_arrow,
                                        size: 36,
                                      ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                state.handler.skipToNext();
                              },
                              icon: const Icon(Icons.skip_next),
                              iconSize: 36,
                              tooltip: 'Next track',
                            ),
                            IconButton(
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                state.toggleRepeat();
                              },
                              icon: Icon(
                                Icons.repeat,
                                color: state.repeatOn
                                    ? UnboundColors.aquaBright
                                    : null,
                              ),
                              tooltip: 'Repeat',
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
            ),
          ),
          // Queue, scrollable once the sheet is fully expanded.
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final queueTrack = playback.queue[i];
                  final isCurrent = i == playback.currentIndex;
                  return TrackRow(
                    track: queueTrack,
                    isCurrent: isCurrent,
                    isPlaying: isCurrent && playback.isPlaying,
                    isLiked: state.isLiked(queueTrack),
                    onTap: () => state.handler.playAt(i),
                    onLike: () => state.toggleLike(queueTrack),
                    onPlayNext: () => state.playNext(queueTrack),
                    onAddToQueue: () => state.addToQueue(queueTrack),
                    onGoToQueue: state.goToQueue,
                    onGoToArtist: () => state.goToArtist(queueTrack.artist),
                    onAddToPlaylist: (context) => showAddToPlaylistDialog(
                      context,
                      state,
                      queueTrack,
                    ),
                    onDownload: () => state.downloadTrack(queueTrack),
                    onShare: () => state.shareTrack(queueTrack),
                    onRecommendSimilar: () =>
                        state.startRadio(queueTrack.artist),
                  );
                },
                childCount: playback.queue.length,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
