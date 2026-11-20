import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/lorebook.dart';
import '../../shared/state/preset_sort.dart';
import '../../shared/widgets/filter_sheet.dart';

/// The Lorebooks list's stored sort, on the same modes and drag order as the
/// Presets list.
final lorebookSortProvider =
    AsyncNotifierProvider<PresetSortNotifier, PresetSortState>(
      () => PresetSortNotifier(
        modeKey: 'lorebookListSortMode',
        orderKey: 'lorebookListManualOrder',
      ),
    );

/// [lorebooks] in the order [state] asks for. A lorebook keeps no creation
/// stamp, so "date" orders by its last change.
List<Lorebook> sortLorebooks(List<Lorebook> lorebooks, PresetSortState state) =>
    sortPresetItems(
      lorebooks,
      state,
      idOf: (lb) => lb.id,
      nameOf: (lb) => lb.name,
      createdAtOf: (lb) => lb.updatedAt,
    );

/// How a lorebook is connected, for the filters.
class LorebookUse {
  final bool global;
  final int characters;
  final int chats;

  const LorebookUse({
    required this.global,
    required this.characters,
    required this.chats,
  });

  bool get unused => !global && characters == 0 && chats == 0;
}

/// What the filter sheet narrows the Lorebooks list to. Each set flag is a
/// kind of connection to show; none set shows every lorebook.
class LorebookListFilters {
  final bool global;
  final bool character;
  final bool chat;
  final bool unused;

  const LorebookListFilters({
    this.global = false,
    this.character = false,
    this.chat = false,
    this.unused = false,
  });

  int get activeCount =>
      (global ? 1 : 0) +
      (character ? 1 : 0) +
      (chat ? 1 : 0) +
      (unused ? 1 : 0);

  bool get isActive => activeCount > 0;

  bool matches(LorebookUse use) {
    if (!isActive) return true;
    return (global && use.global) ||
        (character && use.characters > 0) ||
        (chat && use.chats > 0) ||
        (unused && use.unused);
  }
}

/// Filters for the Lorebooks list on the shared [FilterSheet], applied when
/// the sheet closes (the pattern of the Presets list's filter sheet).
class LorebookFilterSheet extends StatefulWidget {
  final LorebookListFilters filters;
  final ValueChanged<LorebookListFilters> onApply;

  const LorebookFilterSheet({
    super.key,
    required this.filters,
    required this.onApply,
  });

  @override
  State<LorebookFilterSheet> createState() => _LorebookFilterSheetState();
}

class _LorebookFilterSheetState extends State<LorebookFilterSheet> {
  late bool _global = widget.filters.global;
  late bool _character = widget.filters.character;
  late bool _chat = widget.filters.chat;
  late bool _unused = widget.filters.unused;

  @override
  void dispose() {
    final apply = widget.onApply;
    final result = LorebookListFilters(
      global: _global,
      character: _character,
      chat: _chat,
      unused: _unused,
    );
    Future.microtask(() => apply(result));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FilterSheet(
      title: 'catalog_filters'.tr(),
      fitContent: true,
      sections: [
        FilterGroupSection(
          title: 'header_connections'.tr(),
          rows: [
            FilterToggleSection(
              label: 'label_global'.tr(),
              value: _global,
              onChanged: (v) => setState(() => _global = v),
            ),
            FilterToggleSection(
              label: 'header_characters'.tr(),
              value: _character,
              onChanged: (v) => setState(() => _character = v),
            ),
            FilterToggleSection(
              label: 'tab_dialogs'.tr(),
              value: _chat,
              onChanged: (v) => setState(() => _chat = v),
            ),
            FilterToggleSection(
              label: 'lorebook_filter_unused'.tr(),
              value: _unused,
              onChanged: (v) => setState(() => _unused = v),
            ),
          ],
        ),
      ],
    );
  }
}
