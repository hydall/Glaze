import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The chat's own background — base colour, optional image, blur and dim.
///
/// Painted in two places, which is what keeps the desktop layout even: behind
/// the WebView (which is transparent, so the background has to come from
/// Flutter), and across the full column behind [ChatColumnWidth]'s side
/// gutters. Without the second one the capped chat column carried the chat's
/// background while the gutters beside it showed the app's, so the chat read
/// as a lighter strip between two darker bands.
///
/// The two overlap over the column itself, but the upper copy is opaque, so
/// the result is the same as painting it once.
class ChatBackground extends StatelessWidget {
  /// One of `color`, `avatar`, `custom` or `inherit`.
  final String mode;

  /// Base fill, used when [mode] is `color`. Falls back to the theme surface.
  final Color? color;

  /// Character avatar file, used when [mode] is `avatar`.
  final String? avatarPath;

  /// Decoded image for `custom` and `inherit`.
  final Uint8List? imageBytes;

  final double blur;
  final double dim;

  const ChatBackground({
    super.key,
    required this.mode,
    required this.color,
    required this.avatarPath,
    required this.imageBytes,
    required this.blur,
    required this.dim,
  });

  @override
  Widget build(BuildContext context) {
    final base = mode == 'color' && color != null
        ? color!
        : Theme.of(context).colorScheme.surface;

    Widget? image;
    if (mode == 'avatar') {
      final path = avatarPath;
      if (path != null && path.isNotEmpty) {
        image = Image.file(
          File(path),
          fit: BoxFit.cover,
          gaplessPlayback: true,
        );
      }
    } else if (mode != 'color' && imageBytes != null) {
      image = Image.memory(
        imageBytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: base),
        if (image != null) ...[
          if (blur > 0)
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: blur,
                sigmaY: blur,
                tileMode: TileMode.clamp,
              ),
              child: image,
            )
          else
            image,
          if (dim > 0) ColoredBox(color: Colors.black.withValues(alpha: dim)),
        ],
      ],
    );
  }
}
