import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/haptics.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../chat_provider.dart';
import '../quick_replies_provider.dart';
import 'drawer_panel_scaffold.dart';
import 'magic_drawer_models.dart';
import 'magic_drawer_widgets.dart';

class QuickRepliesPanel extends ConsumerStatefulWidget {
  final String charId;
  final bool disableEffects;
  final VoidCallback? onClose;
  final Future<bool> Function()? beforeGeneration;

  const QuickRepliesPanel({
    super.key,
    required this.charId,
    this.onClose,
    this.beforeGeneration,
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

  Future<void> _handleTap(QuickReply reply) async {
    if (_editing) {
      await _showEditSheet(existing: reply);
      return;
    }
    final notifier = ref.read(chatProvider(widget.charId).notifier);
    if (await widget.beforeGeneration?.call() == false) return;
    if (!mounted) return;
    if (reply.isContinueAction) {
      await notifier.continueMessage();
    } else if (reply.text.trim().isNotEmpty) {
      await notifier.sendMessage(reply.text);
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
    final reply = existing;
    final isNew = reply == null;
    // Uses the shared Glaze sheet (glass surface + handle + header) instead of
    // a bare Material sheet, which rendered as a plain light slab.
    await GlazeBottomSheet.show<void>(
      context,
      title: isNew ? 'action_create_new'.tr() : 'action_edit'.tr(),
      child: _QuickReplyEditForm(
        initialLabel: reply?.label ?? '',
        initialText: reply?.text ?? '',
        isNew: isNew,
        onSubmit: (label, text) async {
          final notifier = ref.read(quickRepliesProvider.notifier);
          if (isNew) {
            await notifier.add(label, text);
          } else {
            await notifier.edit(reply.id, label: label, text: text);
          }
        },
        onDelete: isNew ? null : () => _remove(reply.id),
      ),
    );
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

/// Add / edit form for a single quick reply, hosted inside a
/// [GlazeBottomSheet]. Owns its text controllers so the sheet can be dismissed
/// (and the form disposed) without the caller having to keep them alive.
class _QuickReplyEditForm extends StatefulWidget {
  final String initialLabel;
  final String initialText;
  final bool isNew;
  final Future<void> Function(String label, String text) onSubmit;
  final Future<void> Function()? onDelete;

  const _QuickReplyEditForm({
    required this.initialLabel,
    required this.initialText,
    required this.isNew,
    required this.onSubmit,
    this.onDelete,
  });

  @override
  State<_QuickReplyEditForm> createState() => _QuickReplyEditFormState();
}

class _QuickReplyEditFormState extends State<_QuickReplyEditForm> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _textCtrl;

  @override
  void initState() {
    super.initState();
    _labelCtrl = TextEditingController(text: widget.initialLabel);
    _textCtrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final label = _labelCtrl.text.trim();
    if (label.isEmpty) return;
    final text = _textCtrl.text;
    // Captured before the pop — this State is disposed by the time the write
    // completes, so `widget` must not be touched afterwards.
    final onSubmit = widget.onSubmit;
    Navigator.of(context).pop();
    await onSubmit(label, text);
  }

  Future<void> _delete() async {
    final onDelete = widget.onDelete;
    if (onDelete == null) return;
    Navigator.of(context).pop();
    await onDelete();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _labelCtrl,
            autofocus: widget.isNew,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'label_block_name'.tr(),
              hintText: 'placeholder_block_name'.tr(),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _textCtrl,
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
              if (widget.onDelete != null)
                TextButton.icon(
                  onPressed: _delete,
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
                onPressed: () => Navigator.of(context).pop(),
                child: Text('btn_cancel'.tr()),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _submit,
                child: Text(widget.isNew ? 'action_add'.tr() : 'btn_save'.tr()),
              ),
            ],
          ),
        ],
      ),
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
