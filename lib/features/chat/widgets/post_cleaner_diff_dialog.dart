import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/theme/app_colors.dart';
import 'post_cleaner_line_diff.dart';

/// Side-by-side diff viewer for POST-cleaner results.
///
/// Loads the message from the DB by [sessionId]/[messageId], extracts the
/// `final` and `cleaned` agent swipes, and renders them in two parallel
/// scrollable columns with per-line diff highlighting:
/// - red background + `−` prefix: line removed (left side) or changed
/// - green background + `+` prefix: line added (right side) or changed
/// - no highlight: unchanged lines (shown on both sides)
///
/// Opened from the Agentic Operations Log when the user taps "View Diff" on a
/// postCleaner operation.
class PostCleanerDiffDialog extends ConsumerStatefulWidget {
  final String sessionId;
  final String messageId;

  const PostCleanerDiffDialog({
    super.key,
    required this.sessionId,
    required this.messageId,
  });

  static Future<void> show(
    BuildContext context, {
    required String sessionId,
    required String messageId,
  }) {
    return showDialog(
      context: context,
      builder: (_) =>
          PostCleanerDiffDialog(sessionId: sessionId, messageId: messageId),
    );
  }

  @override
  ConsumerState<PostCleanerDiffDialog> createState() =>
      _PostCleanerDiffDialogState();
}

class _PostCleanerDiffDialogState extends ConsumerState<PostCleanerDiffDialog> {
  bool _loading = true;
  String? _error;
  AgentSwipe? _original;
  AgentSwipe? _cleaned;
  DiffResult _diff = const DiffResult.empty();
  final ScrollController _leftController = ScrollController();
  final ScrollController _rightController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadMessage();
  }

  @override
  void dispose() {
    _leftController.dispose();
    _rightController.dispose();
    super.dispose();
  }

  Future<void> _loadMessage() async {
    try {
      final session = await ref
          .read(chatRepoProvider)
          .getById(widget.sessionId);
      if (session == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'Session not found';
        });
        return;
      }
      final msg = session.messages
          .where((m) => m.id == widget.messageId)
          .firstOrNull;
      if (msg == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'Message not found';
        });
        return;
      }

      // Search agentSwipes across ALL green swipes, not just the active one.
      // msg.agentSwipes reflects only the current swipeId — other green
      // swipes keep their blue swipes in swipesMeta[swipeId].
      AgentSwipe? original;
      AgentSwipe? cleaned;

      // First: check the active agentSwipes on the message itself.
      final activeSwipes = msg.agentSwipes;
      for (final s in activeSwipes) {
        if (s.kind == 'cleaned') {
          cleaned = s;
          final parentId = s.parentSwipeId;
          if (parentId != null && parentId < activeSwipes.length) {
            original = activeSwipes[parentId];
          }
        }
      }
      if (original == null && cleaned != null && activeSwipes.isNotEmpty) {
        original = activeSwipes.where((s) => s.kind == 'final').lastOrNull;
      }

      // Second: if not found in active swipes, search swipesMeta for any
      // green swipe that has a 'cleaned' agent swipe.
      if (cleaned == null) {
        for (var si = 0; si < msg.swipesMeta.length; si++) {
          final meta = msg.swipesMeta[si];
          final raw = meta['agentSwipes'];
          if (raw is! List) continue;
          final swipes = raw
              .whereType<Map<dynamic, dynamic>>()
              .map((m) => AgentSwipe.fromJson(Map<String, dynamic>.from(m)))
              .toList();
          for (final s in swipes) {
            if (s.kind == 'cleaned') {
              cleaned = s;
              final parentId = s.parentSwipeId;
              if (parentId != null && parentId < swipes.length) {
                original = swipes[parentId];
              }
              break;
            }
          }
          if (cleaned != null) break;
        }
        if (original == null && cleaned != null) {
          // Fallback: use the message content as the original.
          original = AgentSwipe(content: msg.content, kind: 'final');
        }
      }

      if (!mounted) return;
      setState(() {
        _original = original;
        _cleaned = cleaned;
        _loading = false;
        if (original != null && cleaned != null) {
          _diff = computeLineDiff(original.content, cleaned.content);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Dialog(
      child: SizedBox(
        width: 900,
        height: 600,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.compare_arrows, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Cleaner Diff',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(width: 8),
                  if (_diff.removedLines > 0 || _diff.addedLines > 0)
                    Text(
                      '${_diff.removedLines > 0 ? '-' : ''}${_diff.removedLines} red · '
                      '${_diff.addedLines > 0 ? '+' : ''}${_diff.addedLines} green',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: TextStyle(color: context.cs.error)),
        ),
      );
    }
    if (_original == null || _cleaned == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No cleaner diff available for this message.'),
        ),
      );
    }

    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _buildDiffPanel(
              context,
              label: 'Original',
              accent: cs.onSurfaceVariant,
              lines: _diff.leftLines,
              controller: _leftController,
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _buildDiffPanel(
              context,
              label: 'Cleaned',
              accent: cs.primary,
              lines: _diff.rightLines,
              controller: _rightController,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiffPanel(
    BuildContext context, {
    required String label,
    required Color accent,
    required List<DiffLine> lines,
    required ScrollController controller,
  }) {
    return Container(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Icon(Icons.label_outline, size: 14, color: accent),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Scrollbar(
              controller: controller,
              child: SingleChildScrollView(
                controller: controller,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: lines
                      .map((line) => _buildDiffLine(context, line))
                      .toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiffLine(BuildContext context, DiffLine line) {
    Color bg;
    Color fg;
    String prefix;
    if (line.type == DiffLineType.removed) {
      bg = Colors.red.withValues(alpha: 0.12);
      fg = context.cs.error;
      prefix = '− ';
    } else if (line.type == DiffLineType.added) {
      bg = Colors.green.withValues(alpha: 0.12);
      fg = Colors.green.shade700;
      prefix = '+ ';
    } else {
      bg = Colors.transparent;
      fg = context.cs.onSurface;
      prefix = '  ';
    }

    final changedWordBg = line.type == DiffLineType.removed
        ? Colors.red.withValues(alpha: 0.35)
        : Colors.green.withValues(alpha: 0.35);

    final spans = <TextSpan>[];
    spans.add(
      TextSpan(
        text: prefix,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: fg.withValues(alpha: 0.5),
          fontFamily: 'monospace',
        ),
      ),
    );

    if (line.words != null && line.words!.isNotEmpty) {
      for (var wi = 0; wi < line.words!.length; wi++) {
        final w = line.words![wi];
        // Add space between words (except before the first).
        if (wi > 0) {
          spans.add(
            TextSpan(
              text: ' ',
              style: TextStyle(fontSize: 13, height: 1.4, color: fg),
            ),
          );
        }
        if (w.isChanged) {
          spans.add(
            TextSpan(
              text: w.text.isEmpty ? '\u200B' : w.text,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: fg,
                backgroundColor: changedWordBg,
              ),
            ),
          );
        } else {
          spans.add(
            TextSpan(
              text: w.text,
              style: TextStyle(fontSize: 13, height: 1.4, color: fg),
            ),
          );
        }
      }
    } else {
      spans.add(
        TextSpan(
          text: line.text,
          style: TextStyle(fontSize: 13, height: 1.4, color: fg),
        ),
      );
    }

    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: SelectableText.rich(TextSpan(children: spans)),
    );
  }
}
