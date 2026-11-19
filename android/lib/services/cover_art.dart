// Unbound Muzik — code-drawn covers for tracks without art.
// A gradient derived from the track id/title, so a track with no
// thumbnail still has a distinct, attractive tile instead of a grey box.
// Mirrors the web app's coverArt.ts. No network, no library.

import 'package:flutter/material.dart';

int _hashString(String value) {
  var hash = 0;
  for (var i = 0; i < value.length; i++) {
    hash = (hash * 31 + value.codeUnitAt(i)) | 0;
  }
  return hash.abs();
}

/// Gradient for a tile. Used where an image is not needed.
LinearGradient coverGradient(String seed) {
  final hash = _hashString(seed);
  final hueA = (hash % 360).toDouble();
  final hueB = ((hueA + 50 + (hash % 60)) % 360).toDouble();
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      HSLColor.fromAHSL(1, hueA, 0.75, 0.45).toColor(),
      HSLColor.fromAHSL(1, hueB, 0.80, 0.55).toColor(),
    ],
  );
}

/// A drawn cover tile: gradient background + the track's first letter.
class DrawnCover extends StatelessWidget {
  const DrawnCover({
    super.key,
    required this.seed,
    required this.title,
    this.size = 48,
    this.borderRadius = 10,
    this.fontSize,
  });

  final String seed;
  final String title;
  final double size;
  final double borderRadius;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: coverGradient(seed),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      alignment: Alignment.center,
      child: Text(
        title.isNotEmpty ? title[0].toUpperCase() : '?',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: fontSize ?? size * 0.45,
        ),
      ),
    );
  }
}

/// Cover image when the track has a thumbnail, drawn gradient otherwise.
class TrackCover extends StatelessWidget {
  const TrackCover({
    super.key,
    required this.thumb,
    required this.seed,
    required this.title,
    this.size = 48,
    this.borderRadius = 10,
  });

  final String thumb;
  final String seed;
  final String title;
  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    if (thumb.isEmpty) {
      return DrawnCover(
        seed: seed,
        title: title,
        size: size,
        borderRadius: borderRadius,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Image.network(
        thumb,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => DrawnCover(
          seed: seed,
          title: title,
          size: size,
          borderRadius: borderRadius,
        ),
      ),
    );
  }
}
