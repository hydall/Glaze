import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/models/chat_message.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../lorebooks/lorebook_editor_screen.dart';

/// Vue-parity "Triggered Items" sheet: grouped cards for the lorebook
/// (World Info) entries, memory entries, and regex scripts that fired on a
/// message. Rendered inside the shared [GlazeBottomSheet] frame. Lorebook
/// cards are tappable and open the lorebook editor (as in Glaze/Vue); memory
/// and regex cards are informational only.
void showTriggeredItemsSheet(
  BuildContext context, {
  List<TriggeredEntry> lorebooks = const [],
  List<TriggeredEntry> memories = const [],
  List<TriggeredEntry> regexes = const [],
}) {
  if (lorebooks.isEmpty && memories.isEmpty && regexes.isEmpty) return;

  GlazeBottomSheet.show<void>(
    context,
    title: 'sheet_triggered_items'.tr(),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (lorebooks.isNotEmpty)
            _TriggeredGroup(
              title: 'menu_lorebooks'.tr(),
              cards: [
                for (final e in lorebooks)
                  _TriggeredCard(
                    entry: e,
                    // Pop the modal sheet (root navigator), then open the
                    // owning lorebook on the page navigator.
                    onTap: e.lorebookId.isEmpty
                        ? null
                        : () => _openLorebook(context, e),
                  ),
              ],
            ),
          if (memories.isNotEmpty)
            _TriggeredGroup(
              title: 'chat_memories'.tr(),
              cards: [for (final e in memories) _TriggeredCard(entry: e)],
            ),
          if (regexes.isNotEmpty)
            _TriggeredGroup(
              title: 'menu_regex'.tr(),
              cards: [for (final e in regexes) _TriggeredCard(entry: e)],
            ),
        ],
      ),
    ),
  );
}

void _openLorebook(BuildContext context, TriggeredEntry e) {
  Navigator.of(context, rootNavigator: true).pop();
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LorebookEditorScreen(lorebookId: e.lorebookId),
    ),
  );
}

class _TriggeredGroup extends StatelessWidget {
  final String title;
  final List<Widget> cards;

  const _TriggeredGroup({required this.title, required this.cards});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
          ...cards,
        ],
      ),
    );
  }
}

class _TriggeredCard extends StatelessWidget {
  final TriggeredEntry entry;
  final VoidCallback? onTap;

  const _TriggeredCard({required this.entry, this.onTap});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final isRegex = e.source == 'regex';
    final isMemory = e.source == 'memory';

    final IconData icon = isRegex
        ? Icons.code
        : isMemory
        ? Icons.menu_book_outlined
        : Icons.auto_stories_outlined;

    String sublabel;
    if (isRegex) {
      sublabel = e.pattern.isNotEmpty ? '/${e.pattern}/' : 'Trim Out';
    } else if (isMemory) {
      sublabel = 'label_memory_entry'.tr();
    } else {
      sublabel = e.lorebookName;
    }

    // keyword / vector retrieval badge (lorebook entries only).
    Widget? badge;
    if (!isRegex && !isMemory && (e.source == 'keyword' || e.source == 'vector')) {
      final isVector = e.source == 'vector';
      final color = isVector ? const Color(0xFFBF5AF2) : const Color(0xFF34C759);
      badge = Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(
          e.source,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: color,
          ),
        ),
      );
    }

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: context.cs.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: context.cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        e.name.isNotEmpty ? e.name : 'Unnamed Script',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: context.cs.onSurface,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ?badge,
                  ],
                ),
                if (sublabel.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    sublabel,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.cs.onSurfaceVariant,
                      fontFamily: isRegex ? 'monospace' : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}
