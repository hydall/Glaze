import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../shared/widgets/blurred_image.dart';

/// The chat's own background — base colour, optional image, blur and dim.
///
/// Painted behind the WebView, which is transparent, so the background has to
/// come from Flutter. On desktop the WebView spans the whole middle column even
/// when the messages keep to a narrower one (see [ChatColumnWidth]), so this
/// one surface covers the column edge to edge.
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

    ImageProvider? image;
    if (mode == 'avatar') {
      final path = avatarPath;
      if (path != null && path.isNotEmpty) {
        image = FileImage(File(path));
      }
    } else if (mode != 'color' && imageBytes != null) {
      image = MemoryImage(imageBytes!);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: base),
        if (image != null) ...[
          // Baked once per (image, sigma, size) instead of being re-filtered
          // on every composite — see [BlurredImage].
          BlurredImage(image: image, sigma: blur),
          if (dim > 0) ColoredBox(color: Colors.black.withValues(alpha: dim)),
        ],
      ],
    );
  }
}
