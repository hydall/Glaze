import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/haptics.dart';
import '../../../shared/theme/app_colors.dart';
import '../chat_provider.dart';
import '../quick_replies_provider.dart';
import 'drawer_panel_scaffold.dart';
import 'magic_drawer_models.dart';
import 'magic_drawer_widgets.dart';

class QuickRepliesPanel extends ConsumerStatefulWidget {
  final String charId;
  final bool disableEffects;
  final VoidCallback? onClose;

  const QuickRepliesPanel({
    super.key,
    required this.charId,
    this.onClose,
    this.disableEffects = false,
  });

  @override
  ConsumerState<QuickRepliesPanel> createState() => _QuickRepliesPanelState();
}

class _QuickRepliesPanelState extends ConsumerState<QuickRepliesPanel> {
  bool _editing = false;
  int? _draggingIndex;
  int? _hoverIndex;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _toggleEditing() {
    setState(() => _editing = !_editing);
  }

  void _handleTap(QuickReply reply) {
    if (_editing) {
      _showEditSheet(existing: reply);
      return;
    }
    final notifier = ref.read(chatProvider(widget.charId).notifier);
    if (reply.isContinueAction) {
      notifier.continueMessage();
    } else if (reply.text.trim().isNotEmpty) {
      notifier.sendMessage(reply.text);
    }
    widget.onClose?.call();
  }

  Future<void> _remove(String id) async {
    await ref.read(quickRepliesProvider.notifier).remove(id);
  }

  Future<void> _moveItem(int from, int to) async {
    await ref.read(quickRepliesProvider.notifier).reorder(from, to);
    if (mounted) setState(() => _hoverIndex = null);
  }

  Future<void> _showEditSheet({QuickReply? existing}) async {
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final textCtrl = TextEditingController(text: existing?.text ?? '');
    final isNew = existing == null;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetCtx).bottom,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: context.cs.surfaceContainerHigh,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: context.cs.outlineVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  isNew ? 'action_create_new'.tr() : 'action_edit'.tr(),
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: context.cs.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: labelCtrl,
                  autofocus: isNew,
                  decoration: InputDecoration(
                    labelText: 'label_block_name'.tr(),
                    hintText: 'placeholder_block_name'.tr(),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: textCtrl,
                  maxLines: 4,
                  minLines: 2,
                  decoration: InputDecoration(
                    labelText: 'label_content'.tr(),
                    hintText: 'placeholder_prompt_text'.tr(),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    if (!isNew)
                      TextButton.icon(
                        onPressed: () async {
                          Navigator.of(sheetCtx).pop();
                          await _remove(existing.id);
                        },
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.redAccent,
                        ),
                        label: Text(
                          'btn_delete'.tr(),
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(sheetCtx).pop(),
                      child: Text('btn_cancel'.tr()),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () async {
                        final label = labelCtrl.text.trim();
                        final text = textCtrl.text;
                        if (label.isEmpty) return;
                        Navigator.of(sheetCtx).pop();
                        final notifier = ref.read(
                          quickRepliesProvider.notifier,
                        );
                        if (isNew) {
                          await notifier.add(label, text);
                        } else {
                          await notifier.edit(
                            existing.id,
                            label: label,
                            text: text,
                          );
                        }
                      },
                      child: Text(isNew ? 'action_add'.tr() : 'btn_save'.tr()),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    labelCtrl.dispose();
    textCtrl.dispose();
  }

  String _previewText(QuickReply reply) {
    if (reply.isContinueAction) return 'quick_reply_continue_hint'.tr();
    final t = reply.text.replaceAll('\n', ' ').trim();
    return t.isEmpty ? '—' : t;
  }

  @override
  Widget build(BuildContext context) {
    final repliesAsync = ref.watch(quickRepliesProvider);
    final replies = repliesAsync.value ?? const <QuickReply>[];

    final cards = <MagicDrawerCardItem>[
      for (final r in replies)
        MagicDrawerCardItem(
          def: MagicDrawerItemDef(
            id: r.id,
            label: r.label,
            icon: r.isContinueAction
                ? Icons.keyboard_double_arrow_right
                : Icons.bolt,
            category: MagicDrawerCategory.session,
          ),
          status: _previewText(r),
        ),
      if (_editing)
        MagicDrawerCardItem(
          def: MagicDrawerItemDef(
            id: '__add__',
            label: 'action_add'.tr(),
            icon: Icons.add,
            category: MagicDrawerCategory.session,
          ),
          isAddButton: true,
        ),
    ];

    final content = RawScrollbar(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: 60),
      thickness: 3,
      radius: const Radius.circular(3),
      thumbColor: Colors.white24,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = (constraints.maxWidth - 24 - 12) / 3;
            return SingleChildScrollView(
              controller: _scrollController,
              padding: EdgeInsets.fromLTRB(
                12,
                60,
                12,
                16 + MediaQuery.of(context).padding.bottom,
              ),
              child: MagicCardGrid(
                columns: 3,
                cells: List.generate(cards.length, (index) {
                  final item = cards[index];
                  if (item.isAddButton) {
                    return SizedBox(
                      width: itemWidth,
                      child: AddMagicCard(onTap: () => _showEditSheet()),
                    );
                  }
                  final reply = replies.firstWhere((r) => r.id == item.def.id);
                  final card = MagicCard(
                    item: item,
                    editing: _editing,
                    hovered: _hoverIndex == index && _draggingIndex != index,
                    onTap: () => _handleTap(reply),
                    onDelete: () => _remove(reply.id),
                  );

                  return SizedBox(
                    width: itemWidth,
                    child: DragTarget<int>(
                      onWillAcceptWithDetails: (details) {
                        setState(() => _hoverIndex = index);
                        return details.data != index;
                      },
                      onLeave: (_) {
                        if (_hoverIndex == index) {
                          setState(() => _hoverIndex = null);
                        }
                      },
                      onAcceptWithDetails: (details) {
                        _moveItem(details.data, index);
                      },
                      builder: (context, _, _) {
                        return LongPressDraggable<int>(
                          data: index,
                          delay: const Duration(milliseconds: 300),
                          onDragStarted: () {
                            Haptics.mediumImpact();
                            setState(() {
                              if (!_editing) _editing = true;
                              _draggingIndex = index;
                            });
                          },
                          onDragEnd: (_) {
                            setState(() {
                              _draggingIndex = null;
                              _hoverIndex = null;
                            });
                          },
                          feedback: SizedBox(
                            width: itemWidth,
                            child: Material(
                              color: Colors.transparent,
                              child: Opacity(opacity: 0.92, child: card),
                            ),
                          ),
                          childWhenDragging: Opacity(
                            opacity: 0.25,
                            child: card,
                          ),
                          child: card,
                        );
                      },
                    ),
                  );
                }),
              ),
            );
          },
        ),
      ),
    );

    return DrawerPanelScaffold(
      disableEffects: widget.disableEffects,
      loading: repliesAsync.isLoading && replies.isEmpty,
      onDismiss: widget.onClose,
      header: QuickRepliesHeader(
        editing: _editing,
        onToggleEditing: _toggleEditing,
      ),
      content: content,
    );
  }
}

/// Header for the Quick Replies panel. Mirrors [MagicDrawerHeader]
/// visually but with its own title.
class QuickRepliesHeader extends StatelessWidget {
  final bool editing;
  final VoidCallback onToggleEditing;

  const QuickRepliesHeader({
    super.key,
    required this.editing,
    required this.onToggleEditing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'sheet_title_quick_replies'.tr(),
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
              letterSpacing: -0.2,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: onToggleEditing,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: editing
                    ? context.cs.primary.withValues(alpha: 0.22)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(17),
                border: Border.all(
                  color: editing
                      ? context.cs.primary.withValues(alpha: 0.38)
                      : Colors.white.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    editing ? Icons.check : Icons.edit,
                    size: 16,
                    color: editing ? context.cs.primary : context.cs.onSurface,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    editing ? 'btn_ok'.tr() : 'action_edit'.tr(),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: editing
                          ? context.cs.primary
                          : context.cs.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
