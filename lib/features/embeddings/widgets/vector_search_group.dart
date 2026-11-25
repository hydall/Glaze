import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/lorebook_embedding_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../lorebooks/widgets/lorebook_search_type.dart';

/// How lorebook entries are found by meaning: the search type and the knobs
/// of the vector pass.
///
/// The same global lorebook settings the lorebook list edits, written and
/// persisted the same way, so the two screens can never disagree.
class VectorSearchGroup extends ConsumerStatefulWidget {
  const VectorSearchGroup({super.key});

  @override
  ConsumerState<VectorSearchGroup> createState() => _VectorSearchGroupState();
}

class _VectorSearchGroupState extends ConsumerState<VectorSearchGroup> {
  late final TextEditingController _topKCtrl;
  late final TextEditingController _scanDepthCtrl;

  @override
  void initState() {
    super.initState();
    final s = ref.read(lorebookSettingsProvider);
    _topKCtrl = TextEditingController(text: s.vectorTopK.toString());
    _scanDepthCtrl = TextEditingController(text: s.scanDepth.toString());
  }

  @override
  void dispose() {
    _topKCtrl.dispose();
    _scanDepthCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(lorebookSettingsProvider);
    // Without a configured connection a stored vector mode runs as keyword
    // search, so the picker shows that.
    final configured = ref.watch(embeddingConfiguredProvider);
    final searchType = configured ? s.searchType : 'keyword';

    return MenuGroup(
      compact: true,
      header: 'embeddings_lorebook_search'.tr(),
      items: [
        MenuSelectorItem(
          label: 'label_search_type'.tr(),
          description: lorebookSearchTypeHint(searchType),
          currentValue: lorebookSearchTypeLabel(searchType),
          onTap: () =>
              showLorebookSearchTypeSheet(context, ref, current: searchType),
        ),
        MenuRangeItem(
          label: 'label_similarity_threshold'.tr(),
          value: s.vectorThreshold,
          min: 0,
          max: 1,
          divisions: 100,
          onChanged: (v) => updateLorebookSettings(
            ref,
            s.copyWith(vectorThreshold: double.parse(v.toStringAsFixed(2))),
          ),
        ),
        _NumberField(
          label: 'label_top_k'.tr(),
          controller: _topKCtrl,
          onChanged: (v) {
            final n = int.tryParse(v);
            if (n != null && n >= 1 && n <= 50) {
              updateLorebookSettings(ref, s.copyWith(vectorTopK: n));
            }
          },
        ),
        _NumberField(
          label: 'label_vector_scan_depth'.tr(),
          controller: _scanDepthCtrl,
          onChanged: (v) {
            final n = int.tryParse(v);
            if (n != null && n >= 1 && n <= 100) {
              updateLorebookSettings(ref, s.copyWith(scanDepth: n));
            }
          },
        ),
      ],
    );
  }
}

class _NumberField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _NumberField({
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
