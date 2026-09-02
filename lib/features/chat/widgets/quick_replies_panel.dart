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
  final VoidCallback? onClose;
  final Future<bool> Function()? beforeGeneration;

  /// Edit mode, owned by the hosting [ChatDrawerPanel] so one pencil toggles
  /// both tabs at once.
  final bool editing;

  /// Asks the host to turn edit mode on when a long-press drag starts a
  /// reorder.
  final VoidCallback? onEditingRequested;

  const QuickRepliesPanel({
    super.key,
    required this.charId,
    this.onClose,
    this.beforeGeneration,
    this.editing = false,
    this.onEditingRequested,
  });

  @override
  ConsumerState<QuickRepliesPanel> createState() => _QuickRepliesPanelState();
}

class _QuickRepliesPanelState extends ConsumerState<QuickRepliesPanel> {
  int? _draggingIndex;
  int? _hoverIndex;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _handleTap(QuickReply reply) async {
    if (widget.editing) {
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
        // Continue runs the app's continue-generation call; it has no prompt
        // body to edit and no delete button, so the form drops both.
        builtIn: reply?.isBuiltIn ?? false,
        onSubmit: (label, text) async {
          final notifier = ref.read(quickRepliesProvider.notifier);
          if (isNew) {
            await notifier.add(label, text);
          } else {
            await notifier.edit(reply.id, label: label, text: text);
          }
        },
        onDelete: (isNew || reply.isBuiltIn)
            ? null
            : () => _remove(reply.id),
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
      // Always last, never gated on edit mode: the "+" in the grid is how a
      // new user learns this tab is theirs to fill.
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
      padding: const EdgeInsets.only(top: kDrawerContentTopInset),
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
                kDrawerContentTopInset,
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
                    editing: widget.editing,
                    hovered: _hoverIndex == index && _draggingIndex != index,
                    onTap: () => _handleTap(reply),
                    onDelete: () => _remove(reply.id),
                    deletable: !reply.isBuiltIn,
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
                            if (!widget.editing) {
                              widget.onEditingRequested?.call();
                            }
                            setState(() => _draggingIndex = index);
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

    // The chrome (background, drag handle, header) belongs to the hosting
    // [ChatDrawerPanel] — this is only the tab body.
    return PanelLoadingOverlay(
      loading: repliesAsync.isLoading && replies.isEmpty,
      child: content,
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

  /// True for a built-in action: the prompt field is replaced by a note
  /// explaining what the card does, since its text is never sent.
  final bool builtIn;
  final Future<void> Function(String label, String text) onSubmit;
  final Future<void> Function()? onDelete;

  const _QuickReplyEditForm({
    required this.initialLabel,
    required this.initialText,
    required this.isNew,
    required this.onSubmit,
    this.builtIn = false,
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
          if (widget.builtIn)
            _BuiltInNote(text: 'quick_reply_builtin_note'.tr())
          else
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

/// Explains why a built-in action has no prompt body and no delete button,
/// standing in for the text field the other cards get.
class _BuiltInNote extends StatelessWidget {
  final String text;

  const _BuiltInNote({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: context.cs.primary.withValues(alpha: 0.08),
        border: Border.all(color: context.cs.primary.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: 16, color: context.cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
