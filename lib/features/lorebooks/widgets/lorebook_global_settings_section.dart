import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/lorebook.dart';
import '../../../core/state/lorebook_auto_index_provider.dart';
import '../../../core/state/lorebook_embedding_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../shared/widgets/menu_group.dart';
import 'lorebook_option_sheet.dart';
import 'vector_setup_gate.dart';

/// The global lorebook knobs, as a collapsible block at the top of the
/// lorebook list.
class LorebookGlobalSettingsSection extends ConsumerStatefulWidget {
  const LorebookGlobalSettingsSection({super.key});

  @override
  ConsumerState<LorebookGlobalSettingsSection> createState() =>
      _LorebookGlobalSettingsSectionState();
}

class _LorebookGlobalSettingsSectionState
    extends ConsumerState<LorebookGlobalSettingsSection> {
  late final TextEditingController _scanDepthCtrl;
  late final TextEditingController _maxEntriesCtrl;
  late final TextEditingController _reserveCtrl;
  late final TextEditingController _topKCtrl;

  @override
  void initState() {
    super.initState();
    final s = ref.read(lorebookSettingsProvider);
    _scanDepthCtrl = TextEditingController(text: s.scanDepth.toString());
    _maxEntriesCtrl = TextEditingController(
      text: s.maxInjectedEntries.toString(),
    );
    _reserveCtrl = TextEditingController(text: s.reserveValue.toString());
    _topKCtrl = TextEditingController(text: s.vectorTopK.toString());
  }

  @override
  void dispose() {
    _scanDepthCtrl.dispose();
    _maxEntriesCtrl.dispose();
    _reserveCtrl.dispose();
    _topKCtrl.dispose();
    super.dispose();
  }

  void _update(LorebookGlobalSettings s) {
    ref.read(lorebookSettingsProvider.notifier).state = s;
    saveLorebookSettings(s);
  }

  /// A vector mode is only kept when there is a working embedding connection
  /// to run it on. Without one it would silently behave as keyword search, so
  /// the mode goes back to keys and the user is pointed at the setup instead.
  Future<void> _selectSearchType(String type) async {
    if (type == 'keyword') {
      _update(ref.read(lorebookSettingsProvider).copyWith(searchType: type));
      return;
    }
    final ready = await ensureVectorsReady(context, ref);
    if (!mounted) return;
    final current = ref.read(lorebookSettingsProvider);
    if (!ready) {
      if (current.searchType != 'keyword') {
        _update(current.copyWith(searchType: 'keyword'));
      }
      return;
    }
    _update(current.copyWith(searchType: type));
    if (current.autoIndexVectors) {
      unawaited(ref.read(lorebookAutoIndexerProvider.notifier).scheduleAll());
    }
  }

  static String _searchTypeHint(String type) => switch (type) {
    'vector' => 'search_type_vector_hint'.tr(),
    'both' => 'search_type_both_hint'.tr(),
    _ => 'search_type_keys_hint'.tr(),
  };

  void _setAutoIndex(LorebookGlobalSettings s, bool value) {
    _update(s.copyWith(autoIndexVectors: value));
    if (value) {
      unawaited(ref.read(lorebookAutoIndexerProvider.notifier).scheduleAll());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(lorebookSettingsProvider);

    return MenuCollapsibleSection(
      label: 'section_global_settings'.tr(),
      children: _buildGroups(s),
    );
  }

  /// The global knobs, grouped the way the scan actually runs: what matches
  /// first, then what the semantic pass adds, then how the survivors are
  /// placed in the prompt.
  List<Widget> _buildGroups(LorebookGlobalSettings s) {
    // Without a configured embedding connection a stored vector mode runs as
    // keyword search, so the picker shows that. The vector group stays
    // visible and leads to the embedding setup; choosing a vector mode does
    // the same after checking the connection.
    final configured = ref.watch(embeddingConfiguredProvider);
    final searchType = configured ? s.searchType : 'keyword';
    final isVector = searchType != 'keyword';

    return [
      MenuGroup(
        header: 'lorebook_matching'.tr(),
        helpTerm: 'lorebook-keys',
        items: [
          MenuSelectorItem(
            label: 'label_search_type'.tr(),
            description: _searchTypeHint(searchType),
            currentValue: switch (searchType) {
              'vector' => 'search_type_vector'.tr(),
              'both' => 'search_type_both'.tr(),
              _ => 'search_type_keys'.tr(),
            },
            onTap: () => showLorebookOptionSheet<String>(
              context,
              title: 'label_search_type'.tr(),
              current: searchType,
              options: [
                for (final (type, label) in [
                  ('keyword', 'search_type_keys'),
                  ('vector', 'search_type_vector'),
                  ('both', 'search_type_both'),
                ])
                  LorebookOption(type, label.tr(), hint: _searchTypeHint(type)),
              ],
              onSelect: _selectSearchType,
            ),
          ),
          if (isVector)
            MenuSwitchItem(
              label: 'label_auto_index_vectors'.tr(),
              description: 'hint_auto_index_vectors'.tr(),
              value: s.autoIndexVectors,
              onChanged: (v) => _setAutoIndex(s, v),
            ),
          MenuSelectorItem(
            label: 'label_key_search_mode'.tr(),
            currentValue: s.keySearchMode == 'glaze'
                ? 'match_whole_words_glaze'.tr()
                : 'match_whole_words_st'.tr(),
            onTap: () => showLorebookOptionSheet<String>(
              context,
              title: 'label_key_search_mode'.tr(),
              current: s.keySearchMode,
              options: [
                LorebookOption('tavern', 'match_whole_words_st'.tr()),
                LorebookOption('glaze', 'match_whole_words_glaze'.tr()),
              ],
              onSelect: (v) => _update(s.copyWith(keySearchMode: v)),
            ),
          ),
          _NumberItem(
            label: isVector
                ? 'label_vector_scan_depth'.tr()
                : 'label_scan_depth_lore'.tr(),
            controller: _scanDepthCtrl,
            onChanged: (v) {
              final n = int.tryParse(v);
              if (n != null && n >= 1 && n <= 100) {
                _update(s.copyWith(scanDepth: n));
              }
            },
          ),
          MenuSwitchItem(
            label: 'label_recursive_scan'.tr(),
            value: s.recursiveScan,
            onChanged: (v) => _update(s.copyWith(recursiveScan: v)),
          ),
          MenuSwitchItem(
            label: 'label_case_sensitive'.tr(),
            value: s.caseSensitive,
            onChanged: (v) => _update(s.copyWith(caseSensitive: v)),
          ),
          MenuSwitchItem(
            label: 'label_match_whole_words'.tr(),
            value: s.matchWholeWords,
            onChanged: (v) => _update(s.copyWith(matchWholeWords: v)),
          ),
        ],
      ),
      MenuGroup(
        header: 'section_vector_search'.tr(),
        items: [
          if (!configured) const VectorSetupItem(),
          MenuRangeItem(
            label: 'label_similarity_threshold'.tr(),
            value: s.vectorThreshold,
            min: 0,
            max: 1,
            divisions: 100,
            onChanged: (v) => _update(
              s.copyWith(vectorThreshold: double.parse(v.toStringAsFixed(2))),
            ),
          ),
          _NumberItem(
            label: 'label_top_k'.tr(),
            controller: _topKCtrl,
            onChanged: (v) {
              final n = int.tryParse(v);
              if (n != null && n >= 1 && n <= 50) {
                _update(s.copyWith(vectorTopK: n));
              }
            },
          ),
        ],
      ),
      MenuGroup(
        header: 'section_injection_rules'.tr(),
        helpTerm: 'lorebook-budget',
        items: [
          _NumberItem(
            label: 'label_max_injected_entries'.tr(),
            controller: _maxEntriesCtrl,
            onChanged: (v) {
              final n = int.tryParse(v);
              if (n != null && n >= 1 && n <= 100) {
                _update(s.copyWith(maxInjectedEntries: n));
              }
            },
          ),
          MenuSelectorItem(
            label: 'label_injection_position'.tr(),
            currentValue: switch (s.injectionPosition) {
              'worldInfoAfter' => 'pos_after_char'.tr(),
              'lorebooksMacro' => 'pos_lorebooks_macro'.tr(),
              _ => 'pos_before_char'.tr(),
            },
            onTap: () => showLorebookOptionSheet<String>(
              context,
              title: 'label_injection_position'.tr(),
              current: s.injectionPosition,
              options: [
                LorebookOption('worldInfoBefore', 'pos_before_char'.tr()),
                LorebookOption('worldInfoAfter', 'pos_after_char'.tr()),
                LorebookOption('lorebooksMacro', 'pos_lorebooks_macro'.tr()),
              ],
              onSelect: (v) => _update(s.copyWith(injectionPosition: v)),
            ),
          ),
          MenuSelectorItem(
            label: 'label_lorebook_reserve_mode'.tr(),
            currentValue: s.reserveMode == 'percent'
                ? 'lorebook_reserve_percent'.tr()
                : 'lorebook_reserve_absolute'.tr(),
            onTap: () => showLorebookOptionSheet<String>(
              context,
              title: 'label_lorebook_reserve_mode'.tr(),
              current: s.reserveMode,
              options: [
                LorebookOption('percent', 'lorebook_reserve_percent'.tr()),
                LorebookOption('tokens', 'lorebook_reserve_absolute'.tr()),
              ],
              onSelect: (v) => _update(s.copyWith(reserveMode: v)),
            ),
          ),
          _NumberItem(
            label: s.reserveMode == 'percent'
                ? 'label_lorebook_reserve_percent'.tr()
                : 'label_lorebook_reserve_tokens'.tr(),
            controller: _reserveCtrl,
            onChanged: (v) {
              final n = int.tryParse(v);
              final max = s.reserveMode == 'percent' ? 100 : 2147483647;
              if (n != null && n >= 0 && n <= max) {
                _update(s.copyWith(reserveValue: n));
              }
            },
          ),
        ],
      ),
    ];
  }
}

/// Number row matching [MenuFieldItem] layout but with numeric keyboard.
class _NumberItem extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _NumberItem({
    required this.label,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return MenuFieldItem(
      label: label,
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: onChanged,
    );
  }
}
