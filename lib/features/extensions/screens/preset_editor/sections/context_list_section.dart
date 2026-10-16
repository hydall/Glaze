import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../../shared/theme/app_colors.dart';
import '../../../../../shared/widgets/glaze_action_button.dart';
import '../../../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../../../shared/widgets/glaze_scaffold.dart';
import '../../../../../shared/widgets/glaze_sheet.dart';
import '../../../../../shared/widgets/glaze_toast.dart';
import '../../../../../shared/widgets/menu_group.dart';
import '../../../../../shared/widgets/sheet_view.dart';
import '../../../models/block_context_item.dart';
import '../../../services/block_transfer_service.dart';
import '../../../services/upstream_context_codec.dart';
import 'upstream_block_sections.dart';

String contextTypeLabel(ContextItemType type) => switch (type) {
  ContextItemType.text => 'ctx_type_text'.tr(),
  ContextItemType.lastMessages => 'ctx_type_last_messages'.tr(),
  ContextItemType.lastMessagesKeyword => 'ctx_type_keyword'.tr(),
  ContextItemType.lastMessagesByBlock => 'ctx_type_by_block'.tr(),
  ContextItemType.previousBlock => 'ctx_type_previous_block'.tr(),
};

String contextRoleLabel(ContextItemRole role) => switch (role) {
  ContextItemRole.user => 'ctx_role_user'.tr(),
  ContextItemRole.system => 'ctx_role_system'.tr(),
  ContextItemRole.assistant => 'ctx_role_assistant'.tr(),
};

String separatorLabel(MessagesSeparator separator) => switch (separator) {
  MessagesSeparator.doubleNewline => 'ctx_sep_double_newline'.tr(),
  MessagesSeparator.newline => 'ctx_sep_newline'.tr(),
  MessagesSeparator.space => 'ctx_sep_space'.tr(),
};

/// The original editor's "Context Builder": the ordered items a block's
/// request is built from. Items can be added, edited, switched off, dragged
/// into order, deleted, and moved in and out as the original's `context.json`.
class BlockContextListGroup extends StatelessWidget {
  const BlockContextListGroup({
    required this.items,
    required this.onChanged,
    super.key,
  });

  final List<BlockContextItem> items;
  final ValueChanged<List<BlockContextItem>> onChanged;

  static const _transfer = BlockTransferService();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MenuGroup(
          header: 'ctx_list_header'.tr(),
          headerTrailing: IconButton(
            key: const ValueKey('ctx-list-more'),
            icon: const Icon(Icons.more_horiz, size: 20),
            tooltip: 'ctx_list_actions'.tr(),
            onPressed: () => _showListActions(context),
          ),
          items: [
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'ctx_list_empty'.tr(),
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: _reorder,
              children: [
                for (var i = 0; i < items.length; i++)
                  _ContextItemTile(
                    key: ValueKey(items[i].id),
                    item: items[i],
                    index: i,
                    onToggle: (enabled) =>
                        _replace(items[i].copyWith(disabled: !enabled)),
                    onTap: () => _edit(context, items[i]),
                    onMore: () => _showItemActions(context, items[i]),
                  ),
              ],
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: GlazeActionButton(
            icon: Icons.add,
            label: 'ctx_list_add'.tr(),
            onTap: () => _edit(context, null),
            tone: GlazeActionTone.neutral,
            expand: true,
          ),
        ),
      ],
    );
  }

  void _reorder(int oldIdx, int newIdx) {
    final next = List<BlockContextItem>.from(items);
    final item = next.removeAt(oldIdx);
    next.insert(newIdx, item);
    onChanged(next);
  }

  void _replace(BlockContextItem item) {
    final exists = items.any((i) => i.id == item.id);
    onChanged(
      exists
          ? [for (final i in items) i.id == item.id ? item : i]
          : [...items, item],
    );
  }

  void _edit(BuildContext context, BlockContextItem? item) {
    showGlazeSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ContextItemEditSheet(
        item: item ?? newContextItem(ContextItemType.text),
        onSave: _replace,
      ),
    );
  }

  void _showItemActions(BuildContext context, BlockContextItem item) {
    GlazeBottomSheet.show<void>(
      context,
      items: [
        BottomSheetItem(
          label: 'ctx_item_delete'.tr(),
          icon: Icons.delete_outline,
          isDestructive: true,
          onTap: () {
            Navigator.pop(context);
            onChanged(items.where((i) => i.id != item.id).toList());
          },
        ),
      ],
    );
  }

  void _showListActions(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      items: [
        BottomSheetItem(
          label: 'ctx_list_import'.tr(),
          icon: Icons.file_download_outlined,
          onTap: () {
            Navigator.pop(context);
            _import(context);
          },
        ),
        if (items.isNotEmpty)
          BottomSheetItem(
            label: 'ctx_list_export'.tr(),
            icon: Icons.file_upload_outlined,
            onTap: () {
              Navigator.pop(context);
              _export(context);
            },
          ),
      ],
    );
  }

  /// Replaces the list, as the original's import does.
  Future<void> _import(BuildContext context) async {
    final imported = await _transfer.importContextItems();
    if (imported == null || !context.mounted) return;
    if (imported.isEmpty) {
      GlazeToast.show(context, 'ctx_list_import_failed'.tr(), isError: true);
      return;
    }
    onChanged(imported);
    GlazeToast.show(
      context,
      'ctx_list_imported'.tr(args: ['${imported.length}']),
    );
  }

  Future<void> _export(BuildContext context) async {
    final path = await _transfer.exportContextItems(items);
    if (path.isEmpty || !context.mounted) return;
    GlazeToast.show(context, 'ctx_list_exported'.tr(args: [path]));
  }
}

class _ContextItemTile extends StatelessWidget {
  const _ContextItemTile({
    required this.item,
    required this.index,
    required this.onToggle,
    required this.onTap,
    required this.onMore,
    super.key,
  });

  final BlockContextItem item;
  final int index;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MenuScriptItem(
          name: item.name.isEmpty ? contextTypeLabel(item.type) : item.name,
          subtitle:
              '${contextTypeLabel(item.type)} • ${contextRoleLabel(item.role)}',
          enabled: !item.disabled,
          onToggle: onToggle,
          onTap: onTap,
          onMore: onMore,
        ),
        Positioned(
          right: 110,
          top: 0,
          bottom: 0,
          child: ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.drag_handle, size: 20, color: Colors.white24),
            ),
          ),
        ),
      ],
    );
  }
}

/// Shows a stored affix with its line breaks as `\n`, so it fits one line.
String _escapeAffix(String value) => value.replaceAll('\n', r'\n');

/// The original turns a typed `\n` into a line break when it saves an affix.
String _unescapeAffix(String value) => value.replaceAll(r'\n', '\n');

/// Editor for one context item, the original's item builder.
class ContextItemEditSheet extends StatefulWidget {
  const ContextItemEditSheet({
    required this.item,
    required this.onSave,
    super.key,
  });

  final BlockContextItem item;
  final ValueChanged<BlockContextItem> onSave;

  @override
  State<ContextItemEditSheet> createState() => _ContextItemEditSheetState();
}

class _ContextItemEditSheetState extends State<ContextItemEditSheet> {
  late BlockContextItem _item;
  late final TextEditingController _name;
  late final TextEditingController _text;
  late final TextEditingController _count;
  late final TextEditingController _offset;
  late final TextEditingController _userPrefix;
  late final TextEditingController _userSuffix;
  late final TextEditingController _charPrefix;
  late final TextEditingController _charSuffix;
  late final TextEditingController _keyword;
  late final TextEditingController _blockName;
  late final TextEditingController _blockCount;

  @override
  void initState() {
    super.initState();
    final item = _item = widget.item;
    _name = TextEditingController(text: item.name);
    _text = TextEditingController(text: item.text);
    _count = TextEditingController(text: '${item.messagesCount ?? 10}');
    _offset = TextEditingController(text: '${item.messagesOffset}');
    _userPrefix = TextEditingController(text: _escapeAffix(item.userPrefix));
    _userSuffix = TextEditingController(text: _escapeAffix(item.userSuffix));
    _charPrefix = TextEditingController(text: _escapeAffix(item.charPrefix));
    _charSuffix = TextEditingController(text: _escapeAffix(item.charSuffix));
    _keyword = TextEditingController(text: item.keywordStopper);
    _blockName = TextEditingController(text: item.blockName);
    _blockCount = TextEditingController(text: '${item.blockCount}');
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _text,
      _count,
      _offset,
      _userPrefix,
      _userSuffix,
      _charPrefix,
      _charSuffix,
      _keyword,
      _blockName,
      _blockCount,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Reads the fields back, with the original's fallbacks for numbers that
  /// do not parse.
  BlockContextItem _built() {
    final type = _item.type;
    return _item.copyWith(
      name: _name.text.trim(),
      text: _text.text,
      messagesCount: type == ContextItemType.lastMessages
          ? (int.tryParse(_count.text.trim()) ?? 10)
          : null,
      messagesOffset: int.tryParse(_offset.text.trim()) ?? 0,
      userPrefix: _unescapeAffix(_userPrefix.text),
      userSuffix: _unescapeAffix(_userSuffix.text),
      charPrefix: _unescapeAffix(_charPrefix.text),
      charSuffix: _unescapeAffix(_charSuffix.text),
      keywordStopper: _keyword.text,
      blockName: _blockName.text.trim(),
      blockCount: int.tryParse(_blockCount.text.trim()) ?? 1,
    );
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      GlazeToast.show(context, 'ctx_item_name_required'.tr(), isError: true);
      return;
    }
    widget.onSave(_built());
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final type = _item.type;
    final slicesMessages =
        type == ContextItemType.lastMessages ||
        type == ContextItemType.lastMessagesKeyword ||
        type == ContextItemType.lastMessagesByBlock;
    return SheetView(
      title: 'ctx_item_title'.tr(),
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.check, size: 22),
          tooltip: 'btn_save'.tr(),
          onPressed: _save,
        ),
      ],
      body: Material(
        type: MaterialType.transparency,
        child: ListView(
          children: [
            const SizedBox(height: 8),
            MenuGroup(
              items: [
                MenuFieldItem(
                  label: 'ctx_item_name'.tr(),
                  controller: _name,
                  fieldKey: const ValueKey('ctx-item-name'),
                ),
                MenuSelectorItem(
                  label: 'ctx_item_role'.tr(),
                  currentValue: contextRoleLabel(_item.role),
                  onTap: () => pickBlockOption<ContextItemRole>(
                    context: context,
                    title: 'ctx_item_role'.tr(),
                    options: ContextItemRole.values,
                    current: _item.role,
                    labelOf: contextRoleLabel,
                    onPicked: (v) =>
                        setState(() => _item = _item.copyWith(role: v)),
                  ),
                ),
                MenuSelectorItem(
                  label: 'ctx_item_type'.tr(),
                  currentValue: contextTypeLabel(type),
                  onTap: () => pickBlockOption<ContextItemType>(
                    context: context,
                    title: 'ctx_item_type'.tr(),
                    options: ContextItemType.values,
                    current: type,
                    labelOf: contextTypeLabel,
                    onPicked: (v) =>
                        setState(() => _item = withContextType(_item, v)),
                  ),
                ),
              ],
            ),
            MenuGroup(
              items: [
                if (type == ContextItemType.text)
                  MenuFieldItem(
                    label: 'ctx_item_text'.tr(),
                    helper: 'ctx_item_text_helper'.tr(),
                    controller: _text,
                    maxLines: 10,
                    minLines: 4,
                  ),
                if (type == ContextItemType.lastMessages) ...[
                  MenuFieldItem(
                    label: 'ctx_item_count'.tr(),
                    helper: 'ctx_item_count_helper'.tr(),
                    controller: _count,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                    ),
                  ),
                  MenuFieldItem(
                    label: 'ctx_item_offset'.tr(),
                    helper: 'ctx_item_offset_helper'.tr(),
                    controller: _offset,
                    keyboardType: TextInputType.number,
                  ),
                ],
                if (type == ContextItemType.lastMessagesKeyword)
                  MenuFieldItem(
                    label: 'ctx_item_keyword'.tr(),
                    helper: 'ctx_item_keyword_helper'.tr(),
                    controller: _keyword,
                  ),
                if (type == ContextItemType.lastMessagesByBlock ||
                    type == ContextItemType.previousBlock)
                  MenuFieldItem(
                    label: 'ctx_item_block_name'.tr(),
                    helper: type == ContextItemType.previousBlock
                        ? 'ctx_item_block_name_previous_helper'.tr()
                        : 'ctx_item_block_name_by_block_helper'.tr(),
                    controller: _blockName,
                  ),
                if (type == ContextItemType.previousBlock)
                  MenuFieldItem(
                    label: 'ctx_item_block_count'.tr(),
                    controller: _blockCount,
                    keyboardType: TextInputType.number,
                  ),
                if (slicesMessages) ...[
                  MenuSelectorItem(
                    label: 'ctx_item_separator'.tr(),
                    currentValue: separatorLabel(_item.messagesSeparator),
                    onTap: () => pickBlockOption<MessagesSeparator>(
                      context: context,
                      title: 'ctx_item_separator'.tr(),
                      options: MessagesSeparator.values,
                      current: _item.messagesSeparator,
                      labelOf: separatorLabel,
                      onPicked: (v) => setState(
                        () => _item = _item.copyWith(messagesSeparator: v),
                      ),
                    ),
                  ),
                  MenuFieldItem(
                    label: 'ctx_item_user_prefix'.tr(),
                    controller: _userPrefix,
                  ),
                  MenuFieldItem(
                    label: 'ctx_item_user_suffix'.tr(),
                    controller: _userSuffix,
                  ),
                  MenuFieldItem(
                    label: 'ctx_item_char_prefix'.tr(),
                    controller: _charPrefix,
                  ),
                  MenuFieldItem(
                    label: 'ctx_item_char_suffix'.tr(),
                    helper: 'ctx_item_affix_helper'.tr(),
                    controller: _charSuffix,
                  ),
                ],
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: GlazePillButton(
                  icon: Icons.check_rounded,
                  label: 'btn_save'.tr(),
                  onTap: _save,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
