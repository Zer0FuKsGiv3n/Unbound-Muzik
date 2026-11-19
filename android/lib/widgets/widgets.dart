// Unbound Muzik — small widgets shared across screens.
// Equalizer bars move ONLY when isPlaying is true. The "Playing" pill
// pulses only while playing. Glass appears only on the now-playing card
// and the player bar — never anywhere else.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/track.dart';
import '../services/cover_art.dart';
import '../theme/unbound_theme.dart';

/// Four equalizer bars. They animate only while [playing] is true —
/// a still set of bars means the music is not playing, honestly.
class EqBars extends StatefulWidget {
  const EqBars({super.key, required this.playing, this.height = 16});

  final bool playing;
  final double height;

  @override
  State<EqBars> createState() => _EqBarsState();
}

class _EqBarsState extends State<EqBars> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    if (widget.playing) _controller.repeat();
  }

  @override
  void didUpdateWidget(EqBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.playing && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        // Four bars, out of phase — frozen flat when not playing.
        final heights = widget.playing
            ? <double>[
                4 + 11 * _barHeight(t, 0),
                4 + 11 * _barHeight(t, 0.25),
                4 + 11 * _barHeight(t, 0.5),
                4 + 11 * _barHeight(t, 0.75),
              ]
            : const <double>[4, 4, 4, 4];
        return SizedBox(
          height: widget.height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final h in heights)
                Container(
                  width: 3,
                  height: h,
                  margin: const EdgeInsets.only(right: 2),
                  decoration: BoxDecoration(
                    color: UnboundColors.mint,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  double _barHeight(double t, double phase) {
    final x = (t + phase) % 1.0;
    // Smooth up-and-down: 0 -> 1 -> 0 over the cycle.
    return x < 0.5 ? x * 2 : (1 - x) * 2;
  }
}

/// The status pill: a dot that pulses only while playing, plus plain text.
class PlayingPill extends StatefulWidget {
  const PlayingPill({super.key, required this.statusText, required this.playing});

  final String statusText;
  final bool playing;

  @override
  State<PlayingPill> createState() => _PlayingPillState();
}

class _PlayingPillState extends State<PlayingPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.playing) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(PlayingPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.playing && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        border: Border.all(color: UnboundColors.glassBorder),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return Opacity(
                opacity: widget.playing ? 0.45 + 0.55 * _controller.value : 1,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.playing
                        ? UnboundColors.mint
                        : UnboundColors.textFaint,
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 7),
          Text(
            widget.statusText,
            style: const TextStyle(
              color: UnboundColors.textDim,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

/// Frosted glass panel. Used ONLY for the now-playing card and the
/// player bar — glass is expensive on the A16, so it stays rare.
class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: UnboundColors.glassBg,
            border: Border.all(color: UnboundColors.glassBorder),
            borderRadius: BorderRadius.circular(16),
          ),
          padding: padding ?? const EdgeInsets.all(16),
          child: child,
        ),
      ),
    );
  }
}

/// One track row: cover, title, artist, duration, eq bars when this is
/// the track actually playing, and a Like button.
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.track,
    required this.isCurrent,
    required this.isPlaying,
    required this.isLiked,
    required this.onTap,
    required this.onLike,
    this.trailing,
  });

  final Track track;
  final bool isCurrent;
  final bool isPlaying;
  final bool isLiked;
  final VoidCallback onTap;
  final VoidCallback onLike;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: isCurrent
          ? BoxDecoration(
              color: UnboundColors.violet.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    TrackCover(
                      thumb: track.thumb,
                      seed: track.id + track.title,
                      title: track.title,
                      size: 48,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            [
                              track.artist,
                              formatDuration(track.duration),
                            ].where((s) => s.isNotEmpty).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: UnboundColors.textDim,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isCurrent && isPlaying) ...[
                      const SizedBox(width: 8),
                      const EqBars(playing: true),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (trailing != null) trailing!,
          TextButton(
            onPressed: onLike,
            style: TextButton.styleFrom(
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(
              isLiked ? '♥ Liked' : '♡ Like',
              style: TextStyle(
                color: isLiked
                    ? UnboundColors.violetBright
                    : UnboundColors.textDim,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The fixed player bar (glass): cover, title/artist, previous,
/// play/pause ("Starting…" while starting), next.
class PlayerBar extends StatelessWidget {
  const PlayerBar({
    super.key,
    required this.track,
    required this.isPlaying,
    required this.isStarting,
    required this.onToggle,
    required this.onNext,
    required this.onPrevious,
  });

  final Track? track;
  final bool isPlaying;
  final bool isStarting;
  final VoidCallback onToggle;
  final VoidCallback onNext;
  final VoidCallback onPrevious;

  @override
  Widget build(BuildContext context) {
    final t = track;
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (t != null)
            TrackCover(
              thumb: t.thumb,
              seed: t.id + t.title,
              title: t.title,
              size: 48,
            )
          else
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: UnboundColors.ink,
                border: Border.all(color: UnboundColors.glassBorder),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t?.title ?? 'Nothing playing',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  t?.artist ?? 'Unbound Muzik',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: UnboundColors.textDim,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: t == null
                ? null
                : () {
                    HapticFeedback.lightImpact();
                    onPrevious();
                  },
            icon: const Icon(Icons.skip_previous),
            iconSize: 28,
            tooltip: 'Previous track',
          ),
          SizedBox(
            width: 56,
            height: 56,
            child: ElevatedButton(
              onPressed: () {
                HapticFeedback.lightImpact();
                onToggle();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: UnboundColors.violet,
                foregroundColor: Colors.white,
                shape: const CircleBorder(),
                padding: EdgeInsets.zero,
              ),
              child: isStarting
                  ? const Text(
                      '…',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    )
                  : Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 28,
                    ),
            ),
          ),
          IconButton(
            onPressed: t == null
                ? null
                : () {
                    HapticFeedback.lightImpact();
                    onNext();
                  },
            icon: const Icon(Icons.skip_next),
            iconSize: 28,
            tooltip: 'Next track',
          ),
        ],
      ),
    );
  }
}

/// Seek bar with a local drag value (just_audio's official pattern).
/// While dragging, the thumb follows the finger and live position ticks
/// are ignored; on release the local value is cleared and the stream
/// resumes driving the thumb. Seeks once, on release (onChangeEnd) —
/// never continuously while dragging. Position stays out of AppState;
/// this widget is driven by a StreamBuilder on the handler's position
/// stream, so only it rebuilds on each tick.
class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.duration,
    required this.position,
    required this.bufferedPosition,
    required this.onChangeEnd,
  });

  final Duration duration;
  final Duration position;
  final Duration bufferedPosition;
  final ValueChanged<Duration> onChangeEnd;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragValue;
  // Last whole-second boundary a scrub tick fired at. The detent tick
  // fires only when crossing a boundary — never on every onChanged
  // tick, or the drag would buzz continuously.
  double _lastHapticSecond = -1;

  String _format(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = widget.duration.inMilliseconds.toDouble();
    final positionMs = widget.position.inMilliseconds.toDouble();
    final bufferedMs = widget.bufferedPosition.inMilliseconds.toDouble();
    // Disable the slider until the duration is known. A Slider with
    // max == min is disabled by Flutter, so guard explicitly.
    final enabled = widget.duration > Duration.zero;
    final maxMs = durationMs > 0 ? durationMs : 1.0;
    final value =
        (_dragValue ?? positionMs).clamp(0.0, maxMs);
    final bufferedValue = durationMs > 0
        ? (bufferedMs / durationMs).clamp(0.0, 1.0)
        : 0.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: UnboundColors.violet,
            inactiveTrackColor: UnboundColors.glassBorder,
            thumbColor: UnboundColors.violetBright,
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            min: 0,
            max: enabled ? durationMs : 1,
            value: enabled ? value : 0,
            onChangeStart: enabled
                ? (_) {
                    HapticFeedback.mediumImpact();
                    _lastHapticSecond = -1;
                  }
                : null,
            onChanged: enabled
                ? (v) {
                    setState(() => _dragValue = v);
                    // Detent tick only when crossing a whole-second
                    // boundary (start 1s; tune to 5s if it feels busy).
                    final second = (v / 1000).floorToDouble();
                    if (second != _lastHapticSecond) {
                      _lastHapticSecond = second;
                      HapticFeedback.selectionClick();
                    }
                  }
                : null,
            onChangeEnd: enabled
                ? (v) {
                    _dragValue = null;
                    HapticFeedback.lightImpact();
                    widget.onChangeEnd(Duration(milliseconds: v.round()));
                  }
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Text(
                _format(widget.position),
                style: const TextStyle(
                  color: UnboundColors.textDim,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LinearProgressIndicator(
                  value: bufferedValue,
                  backgroundColor: UnboundColors.glassBorder,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    UnboundColors.sky,
                  ),
                  minHeight: 2,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _format(widget.duration),
                style: const TextStyle(
                  color: UnboundColors.textDim,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
