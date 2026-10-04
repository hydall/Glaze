import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../../../shared/theme/app_colors.dart';

/// Renders a prompt message's content the way the model will read it, but
/// legibly — markdown, with remote images allowed and everything else refused.
///
/// Lives next to the inspector rather than inside one screen: both the next
/// request and a captured one render their messages with it.
class PromptMarkdownPreview extends StatelessWidget {
  final String content;

  const PromptMarkdownPreview({super.key, required this.content});

  @override
  Widget build(BuildContext context) {
    return GptMarkdown(
      content,
      style: TextStyle(fontSize: 12, color: context.cs.onSurface),
      imageBuilder: (context, url, width, height) {
        final uri = Uri.tryParse(url);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
          return const Icon(
            Icons.broken_image_outlined,
            key: ValueKey('prompt-markdown-image-unavailable'),
          );
        }
        return Image.network(
          url,
          key: const ValueKey('prompt-markdown-image'),
          width: width,
          height: height,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
        );
      },
    );
  }
}

/// One image a prompt message carries, decoded from its `data:` URI. Anything
/// that is not an inline image — a remote URL, a malformed payload, one past
/// the size cap — falls back to a placeholder rather than fetching it.
class PromptAttachmentPreview extends StatefulWidget {
  final String imagePath;
  final bool expanded;

  const PromptAttachmentPreview({
    super.key,
    required this.imagePath,
    this.expanded = false,
  });

  @override
  State<PromptAttachmentPreview> createState() =>
      _PromptAttachmentPreviewState();
}

class _PromptAttachmentPreviewState extends State<PromptAttachmentPreview> {
  static const _maxEncodedLength = 8 * 1024 * 1024;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(PromptAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imagePath != oldWidget.imagePath) _decode();
  }

  void _decode() {
    final match = RegExp(
      r'^data:image/(?:png|jpeg|jpg|gif|webp);base64,([A-Za-z0-9+/=]+)$',
      caseSensitive: false,
    ).firstMatch(widget.imagePath);
    final encoded = match?.group(1);
    if (encoded == null || encoded.length > _maxEncodedLength) {
      _bytes = null;
      return;
    }
    try {
      _bytes = base64Decode(encoded);
    } on FormatException {
      _bytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null || bytes.isEmpty) return _unavailable(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.memory(
        bytes,
        key: const ValueKey('prompt-attachment-image'),
        width: double.infinity,
        height: widget.expanded ? 220 : 96,
        cacheWidth: widget.expanded ? 1024 : 480,
        cacheHeight: widget.expanded ? 640 : 288,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _unavailable(context),
      ),
    );
  }

  Widget _unavailable(BuildContext context) => Container(
    key: const ValueKey('prompt-attachment-unavailable'),
    height: 56,
    width: double.infinity,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: context.cs.onSurface.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(
      Icons.broken_image_outlined,
      color: context.cs.onSurfaceVariant,
    ),
  );
}
