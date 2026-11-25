// Unbound Muzik — teleport transitions, v2 (Daniel, 2026-11-24).
//
// The first teleport was one effect: a 126-degree twist, every time.
// Daniel's call: too simple. He wants the "wait...? what was that!?"
// caught-off-guard feeling, on EVERY screen change, and he said to
// play with it — so each switch is a different visual from the last,
// and never two of the same in a row.
//
// Four effects, one picker. The picker is shared by tab switches and
// pushed routes (Settings), so a tab switch followed by opening
// Settings is two different visuals too. The picker remembers the
// last effect and never returns it twice in a row.
//
// Every effect is a full out-and-in over 400ms: the old screen
// leaves in the first half, the tab swaps at the midpoint, the new
// screen arrives from the other direction in the second half. At
// t == 0 and t == 1 every effect is the identity, so a finished
// transition leaves the screen exactly where it started.
//
// The four effects:
// - twist: the original, strengthened — a half turn (180 degrees)
//   with the screen shrinking to half size as it goes.
// - portal: the screen zooms INTO itself, through the vortex, and
//   the new one zooms back out the other side.
// - flip: the screen flips over like a card, edge-on at the midpoint.
// - swoop: the old screen sweeps off diagonally up-right, the new
//   one sweeps in from down-left.
//
// The Now Playing sheet is deliberately NOT twisted: it is the
// persistent player, and music keeps playing while the content
// behind it teleports.

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The four teleport effects. A screen change picks one at random,
/// never the same as the last change.
enum TeleportEffect { twist, portal, flip, swoop }

/// Picks the next effect. Remembers the last one and never returns
/// it twice in a row. Shared by tab switches and pushed routes, so
/// consecutive screen changes are always different visuals.
class TeleportEffectPicker {
  static final _random = math.Random();
  static TeleportEffect _last = TeleportEffect.twist;

  static TeleportEffect next() {
    final values = TeleportEffect.values;
    var pick = values[_random.nextInt(values.length)];
    if (pick == _last) {
      // Step to a different one (random offset, so the sequence
      // does not just cycle in order).
      pick = values[
          (_last.index + 1 + _random.nextInt(values.length - 1)) %
              values.length];
    }
    _last = pick;
    return pick;
  }
}

/// The full twist, out and back in. 400ms — a jump, not a slow spin.
const Duration teleportDuration = Duration(milliseconds: 400);

/// The transform for an effect at a twist value [t] in 0..1.
/// 0..0.5 is the old screen leaving, 0.5..1 is the new screen
/// arriving from the other direction. [rotation] is in turns,
/// [flipY] in radians (a Y-axis card flip), [offset] is a fraction
/// of the screen size, [scale] and [opacity] are multipliers.
({double rotation, double scale, double opacity, Offset offset, double flipY})
    teleportEffectAt(TeleportEffect effect, double t) {
  final out = t < 0.5;
  // u runs 0..1 within the current half.
  final u = out ? t / 0.5 : (t - 0.5) / 0.5;
  switch (effect) {
    case TeleportEffect.twist:
      // Half a turn out, half a turn back in from the other side,
      // shrinking to half size at the midpoint.
      if (out) {
        return (
          rotation: u * 0.5,
          scale: 1 - u * 0.5,
          opacity: 1 - u * 0.6,
          offset: Offset.zero,
          flipY: 0,
        );
      }
      return (
        rotation: -(1 - u) * 0.5,
        scale: 0.5 + u * 0.5,
        opacity: 0.4 + u * 0.6,
        offset: Offset.zero,
        flipY: 0,
      );
    case TeleportEffect.portal:
      // Zoom INTO the screen, through the vortex, and back out the
      // other side. The scale blows past the edges so the screen
      // feels like it swallowed the view.
      if (out) {
        return (
          rotation: 0,
          scale: 1 + u * 0.8,
          opacity: 1 - u,
          offset: Offset.zero,
          flipY: 0,
        );
      }
      return (
        rotation: 0,
        scale: 1.8 - u * 0.8,
        opacity: u,
        offset: Offset.zero,
        flipY: 0,
      );
    case TeleportEffect.flip:
      // A card flip around the vertical axis. Edge-on (90 degrees)
      // at the midpoint, which is exactly where the tab swaps, so
      // the swap is invisible — the new screen is simply the other
      // side of the card.
      if (out) {
        return (
          rotation: 0,
          scale: 1,
          opacity: 1,
          offset: Offset.zero,
          flipY: u * (math.pi / 2),
        );
      }
      return (
        rotation: 0,
        scale: 1,
        opacity: 1,
        offset: Offset.zero,
        flipY: -(1 - u) * (math.pi / 2),
      );
    case TeleportEffect.swoop:
      // The old screen sweeps off diagonally up-right with a
      // quarter-turn lean; the new one sweeps in from down-left.
      if (out) {
        return (
          rotation: u * 0.15,
          scale: 1 - u * 0.2,
          opacity: 1 - u * 0.7,
          offset: Offset(u * 0.6, -u * 0.6),
          flipY: 0,
        );
      }
      return (
        rotation: -(1 - u) * 0.15,
        scale: 0.8 + u * 0.2,
        opacity: 0.3 + u * 0.7,
        offset: Offset(-(1 - u) * 0.6, (1 - u) * 0.6),
        flipY: 0,
      );
  }
}

/// Applies one teleport effect at twist value [t] to [child].
/// A pure function of (effect, t): the same inputs always give
/// the same frame, so the animation is deterministic.
class TeleportEffectView extends StatelessWidget {
  const TeleportEffectView({
    super.key,
    required this.effect,
    required this.t,
    required this.child,
  });

  final TeleportEffect effect;
  final double t;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final v = teleportEffectAt(effect, t);
    Widget w = child;
    if (v.offset != Offset.zero) {
      w = FractionalTranslation(translation: v.offset, child: w);
    }
    if (v.flipY != 0) {
      w = Transform(
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.001)
          ..rotateY(v.flipY),
        alignment: Alignment.center,
        child: w,
      );
    }
    if (v.rotation != 0) {
      w = Transform.rotate(angle: v.rotation * math.pi * 2, child: w);
    }
    if (v.scale != 1) {
      w = Transform.scale(scale: v.scale, child: w);
    }
    if (v.opacity != 1) {
      w = Opacity(opacity: v.opacity.clamp(0, 1), child: w);
    }
    return w;
  }
}

/// A route that teleports the pushed page in with one of the four
/// effects. The effect is picked when the route is created
/// (TeleportEffectPicker.next()), so every push is a different
/// visual from the last screen change. Only the in-half of the
/// effect plays here (the new page arriving); on pop the animation
/// reverses and the page teleports back out the way it came in.
class TeleportPageRoute<T> extends PageRouteBuilder<T> {
  TeleportPageRoute({
    required this.effect,
    required Widget Function(BuildContext context) builder,
  }) : super(
          transitionDuration: teleportDuration,
          reverseTransitionDuration: teleportDuration,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) {
            // Map the route animation (0..1 on push) onto the
            // in-half of the effect (0.5..1).
            final t = 0.5 + animation.value * 0.5;
            return TeleportEffectView(effect: effect, t: t, child: child);
          },
        );

  final TeleportEffect effect;
}
