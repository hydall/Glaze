import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/lorebook_embedding_text.dart';
import '../../../core/models/lorebook.dart';
import '../../../core/state/lorebook_embedding_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../shared/widgets/menu_group.dart';
import 'lorebook_option_sheet.dart';

/// One lorebook's own overrides, as a collapsible block above its entries.
///
/// [settings] null means the book follows the global settings; the rows then
/// show the global values, and the first change turns them into the book's
/// own copy. [onChanged] receives the new overrides, or null after a reset.
class LorebookBookSettingsSection extends ConsumerStatefulWidget {
  final LorebookSettings? settings;
  final ValueChanged<LorebookSettings?> onChanged;

  const LorebookBookSettingsSection({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  @override
  ConsumerState<LorebookBookSettingsSection> createState() =>
      _LorebookBookSettingsSectionState();
}

class _LorebookBookSettingsSectionState
    extends ConsumerState<LorebookBookSettingsSection> {
  final _scanDepthCtrl = TextEditingController();
  final _maxEntriesCtrl = TextEditingController();
  final _topKCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _syncControllers();
  }

  @override
  void didUpdateWidget(LorebookBookSettingsSection old) {
    super.didUpdateWidget(old);
    if (old.settings != widget.settings) _syncControllers();
  }

  @override
  void dispose() {
    _scanDepthCtrl.dispose();
    _maxEntriesCtrl.dispose();
    _topKCtrl.dispose();
    super.dispose();
  }

  /// Rewrites a field only when it disagrees with the value, so the caret is
  /// not thrown to the end of a field the user is typing in.
  void _syncControllers() {
    final s = _effective;
    void sync(TextEditingController ctrl, String text) {
      if (ctrl.text != text) ctrl.text = text;
    }

    sync(_scanDepthCtrl, s.scanDepth?.toString() ?? '');
    sync(_maxEntriesCtrl, s.maxInjectedEntries?.toString() ?? '');
    sync(_topKCtrl, s.vectorTopK.toString());
  }

  /// What the rows show: the book's own overrides, or the global values it is
  /// currently following.
  LorebookSettings get _effective =>
      widget.settings ?? _fromGlobal(ref.read(lorebookSettingsProvider));

  static LorebookSettings _fromGlobal(LorebookGlobalSettings g) {
    return LorebookSettings(
      recursiveScan: g.recursiveScan,
      caseSensitive: g.caseSensitive,
      matchWholeWords: g.matchWholeWords ? 'true' : 'false',
      vectorThreshold: g.vectorThreshold,
      vectorTopK: g.vectorTopK,
    );
  }

  void _update(LorebookSettings s) => widget.onChanged(s);

  @override
  Widget build(BuildContext context) {
    // Keeps the inherited values current while the book has no overrides.
    ref.watch(lorebookSettingsProvider);
    final s = _effective;
    final hasCustom = widget.settings != null;
    // Hidden while the active API preset has semantic search off: the
    // per-book vector overrides could not take effect anyway.
    final vectorAvailable = ref.watch(vectorSearchAvailableProvider);

    return MenuCollapsibleSection(
      label: 'title_lorebook_settings'.tr(),
      children: [
        MenuGroup(
          header: 'section_scan_recursion'.tr(),
          helpTerm: 'lorebook-recursion',
          description: hasCustom ? null : 'lorebook_using_global_defaults'.tr(),
          items: [
            _NumberItem(
              label: 'label_scan_depth_lore'.tr(),
              controller: _scanDepthCtrl,
              placeholder: 'lorebook_global_default_hint'.tr(),
              onChanged: (v) {
                final n = int.tryParse(v);
                if (v.isEmpty || n == 0) {
                  _update(s.copyWith(scanDepth: null));
                } else if (n != null && n <= 100) {
                  _update(s.copyWith(scanDepth: n));
                }
              },
            ),
            _NumberItem(
              label: 'label_max_injected_entries'.tr(),
              description: 'lorebook_book_entry_cap_hint'.tr(),
              controller: _maxEntriesCtrl,
              placeholder: 'lorebook_global_default_hint'.tr(),
              onChanged: (v) {
                final n = int.tryParse(v);
                if (v.isEmpty || n == 0) {
                  _update(s.copyWith(maxInjectedEntries: null));
                } else if (n != null && n <= 100) {
                  _update(s.copyWith(maxInjectedEntries: n));
                }
              },
            ),
          ],
        ),
        MenuGroup(
          header: 'lorebook_matching'.tr(),
          helpTerm: 'lorebook-keys',
          items: [
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
            MenuSelectorItem(
              label: 'label_match_whole_words'.tr(),
              currentValue: switch (s.matchWholeWords) {
                'false' => 'off'.tr(),
                'true' => 'on'.tr(),
                'glaze' => 'match_whole_words_glaze'.tr(),
                _ => 'match_global'.tr(),
              },
              onTap: () => showLorebookOptionSheet<String>(
                context,
                title: 'label_match_whole_words'.tr(),
                current: s.matchWholeWords ?? '',
                options: [
                  LorebookOption('', 'match_global'.tr()),
                  LorebookOption('false', 'off'.tr()),
                  LorebookOption('true', 'on'.tr()),
                  LorebookOption('glaze', 'match_whole_words_glaze'.tr()),
                ],
                onSelect: (v) => _update(
                  s.copyWith(matchWholeWords: v.isEmpty ? null : v),
                ),
              ),
            ),
          ],
        ),
        if (vectorAvailable) _vectorGroup(s),
        if (hasCustom)
          MenuGroup(
            items: [
              MenuItem(
                icon: Icons.undo_rounded,
                label: 'lorebook_reset_to_global'.tr(),
                onTap: () => widget.onChanged(null),
              ),
            ],
          ),
      ],
    );
  }

  Widget _vectorGroup(LorebookSettings s) {
    final target = LorebookEmbeddingTarget.values.contains(s.embeddingTarget)
        ? s.embeddingTarget
        : LorebookEmbeddingTarget.content;
    return MenuGroup(
      header: 'section_vector_search'.tr(),
      items: [
        MenuSwitchItem(
          label: 'label_vector_search'.tr(),
          value: s.vectorSearchEnabled,
          onChanged: (v) => _update(s.copyWith(vectorSearchEnabled: v)),
        ),
        if (s.vectorSearchEnabled) ...[
          MenuSwitchItem(
            label: 'label_vectorize_all_entries'.tr(),
            value: s.vectorizeAllEntries,
            onChanged: (v) => _update(s.copyWith(vectorizeAllEntries: v)),
          ),
          MenuSelectorItem(
            label: 'label_embedding_target'.tr(),
            currentValue: switch (target) {
              LorebookEmbeddingTarget.comment => 'target_comment'.tr(),
              LorebookEmbeddingTarget.keys => 'target_keys'.tr(),
              LorebookEmbeddingTarget.both => 'target_comment_and_content'.tr(),
              _ => 'target_content'.tr(),
            },
            onTap: () => showLorebookOptionSheet<String>(
              context,
              title: 'label_embedding_target'.tr(),
              current: target,
              options: [
                LorebookOption(
                  LorebookEmbeddingTarget.content,
                  'target_content'.tr(),
                ),
                LorebookOption(
                  LorebookEmbeddingTarget.comment,
                  'target_comment'.tr(),
                ),
                LorebookOption(
                  LorebookEmbeddingTarget.keys,
                  'target_keys'.tr(),
                ),
                LorebookOption(
                  LorebookEmbeddingTarget.both,
                  'target_comment_and_content'.tr(),
                ),
              ],
              onSelect: (v) => _update(s.copyWith(embeddingTarget: v)),
            ),
          ),
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
      ],
    );
  }
}

/// Number row matching [MenuFieldItem] layout but with numeric keyboard.
class _NumberItem extends StatelessWidget {
  final String label;
  final String? description;
  final String? placeholder;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _NumberItem({
    required this.label,
    this.description,
    this.placeholder,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return MenuFieldItem(
      label: label,
      description: description,
      placeholder: placeholder,
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: onChanged,
    );
  }
}
