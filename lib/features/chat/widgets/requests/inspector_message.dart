import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/llm/tokenizer.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../services/prompt_preview_post_processor.dart';
import 'inspector_surface.dart';
import 'prompt_attachment_preview.dart';

/// Role accents. Semantic status colours with no token behind them, so they are
/// hoisted here rather than repeated inline (`docs/UI_KIT.md` § Colours).
const Color _systemAccent = Color(0xFF5B8DEF);
const Color _userAccent = Color(0xFFB57BE0);
const Color _assistantAccent = Color(0xFF4CAF7D);
const Color _otherAccent = Color(0xFF9AA0A6);
const Color _depthAccent = Color(0xFFE0A030);

/// One message of a request, in the shape the inspector renders.
///
/// Both sides of the inspector build it: the next request from the built prompt
/// (which knows which block a message came from and whether post-processing
/// merged several), and a captured request from the JSON that actually went out
/// (which knows only role and content). Everything the capture cannot answer is
/// optional, so one card renders both.
class InspectorMessage {
  const InspectorMessage({
    required this.role,
    required this.content,
    this.blockName,
    this.depth,
    this.imagePaths = const [],
    this.mergedCount = 0,
    this.isLorebook = false,
    this.isHistory = false,
    this.isDepth = false,
  });

  final String role;
  final String content;

  /// Name of the prompt block this message was built from, when it is known.
  final String? blockName;
  final int? depth;
  final List<String> imagePaths;

  /// How many built blocks post-processing folded into this one message. 0 or 1
  /// means nothing was merged.
  final int mergedCount;

  final bool isLorebook;
  final bool isHistory;
  final bool isDepth;

  /// A system message that is neither history nor lorebook — the instruction
  /// blocks the `System` filter is about.
  bool get isPlainSystem => role == 'system' && !isHistory && !isLorebook;

  /// The built prompt's view of a message, with everything the preview knows.
  factory InspectorMessage.fromPreview(PreviewMessage row) {
    final message = row.message;
    return InspectorMessage(
      role: message.role,
      content: message.content,
      blockName: message.blockName,
      depth: message.depth,
      imagePaths: row.imagePaths,
      mergedCount: row.sources.length,
      isLorebook: message.isLorebook,
      isHistory: message.isHistory,
      isDepth: message.isDepth,
    );
  }

  /// A captured request's message, straight from the payload that went out.
  /// Non-string content (multimodal parts, tool payloads) is kept as its JSON
  /// so nothing is silently dropped from the record.
  factory InspectorMessage.fromCapture(Map<String, dynamic> message) {
    final content = message['content'];
    return InspectorMessage(
      role: '${message['role'] ?? 'unknown'}',
      content: content is String
          ? content
          : content == null
          ? ''
          : const JsonEncoder.withIndent('  ').convert(content),
    );
  }
}

/// One message of a request: collapsed to its header and a two-line preview,
/// expanded to its attachments and its rendered content.
class InspectorMessageCard extends StatefulWidget {
  const InspectorMessageCard({
    super.key,
    required this.index,
    required this.message,
    this.renderMarkdown = true,
  });

  final int index;
  final InspectorMessage message;

  /// A captured request is a record, so it shows its content verbatim; the next
  /// request renders markdown, which is how the model's input reads.
  final bool renderMarkdown;

  @override
  State<InspectorMessageCard> createState() => _InspectorMessageCardState();
}

class _InspectorMessageCardState extends State<InspectorMessageCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final images = message.imagePaths;

    return InspectorPlaque(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      accent: _roleAccent(message.role),
      onTap: () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(context, message),
          if (!_expanded && message.content.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              message.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ],
          // A merge can pull several attachments into one message, so every
          // source image is listed rather than just the first.
          if (!_expanded)
            for (final path in images) ...[
              const SizedBox(height: 8),
              PromptAttachmentPreview(imagePath: path),
            ],
          if (_expanded) ...[
            const SizedBox(height: 8),
            for (final path in images) ...[
              PromptAttachmentPreview(imagePath: path, expanded: true),
              const SizedBox(height: 8),
            ],
            if (message.content.isNotEmpty)
              InspectorTextBox(
                child: widget.renderMarkdown
                    ? PromptMarkdownPreview(content: message.content)
                    : SelectableText(
                        message.content,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: context.cs.onSurface,
                        ),
                      ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _header(BuildContext context, InspectorMessage message) {
    final tokens = estimateTokens(message.content);

    return Row(
      children: [
        InspectorRoleChip(role: message.role),
        if (message.mergedCount > 1) ...[
          const SizedBox(width: 4),
          _MergedBadge(count: message.mergedCount),
        ],
        if (message.blockName != null) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message.blockName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const Spacer(),
        Text(
          '#${widget.index + 1}',
          style: TextStyle(
            fontSize: 10,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$tokens t',
          style: TextStyle(fontSize: 10, color: context.cs.onSurfaceVariant),
        ),
        if (message.isDepth && message.depth != null) ...[
          const SizedBox(width: 4),
          _Badge(label: 'd${message.depth}', color: _depthAccent),
        ],
        Icon(
          _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
          size: 16,
          color: context.cs.onSurfaceVariant,
        ),
      ],
    );
  }
}

/// The role tag every message card leads with.
class InspectorRoleChip extends StatelessWidget {
  const InspectorRoleChip({super.key, required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final accent = _roleAccent(role);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.18),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        role.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: accent,
        ),
      ),
    );
  }
}

Color _roleAccent(String role) => switch (role) {
  'system' => _systemAccent,
  'user' => _userAccent,
  'assistant' => _assistantAccent,
  _ => _otherAccent,
};

/// How many built blocks post-processing folded into this one message. Without
/// it a merged card reads as one oversized block and nothing on screen says the
/// connection reshaped the prompt.
class _MergedBadge extends StatelessWidget {
  const _MergedBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final color = context.cs.primary;
    return Tooltip(
      message: 'prompt_preview_merged_blocks'.tr(args: ['$count']),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.merge_rounded, size: 11, color: color),
            const SizedBox(width: 2),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
