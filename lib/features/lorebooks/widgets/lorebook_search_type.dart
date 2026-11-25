import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/lorebook.dart';
import '../../../core/state/lorebook_auto_index_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import 'lorebook_option_sheet.dart';
import 'vector_setup_gate.dart';

/// Writes the global lorebook settings and persists them.
void updateLorebookSettings(WidgetRef ref, LorebookGlobalSettings settings) {
  ref.read(lorebookSettingsProvider.notifier).state = settings;
  saveLorebookSettings(settings);
}

/// The label of a stored search type.
String lorebookSearchTypeLabel(String type) => switch (type) {
  'vector' => 'search_type_vector'.tr(),
  'both' => 'search_type_both'.tr(),
  _ => 'search_type_keys'.tr(),
};

/// One line on what a search type does.
String lorebookSearchTypeHint(String type) => switch (type) {
  'vector' => 'search_type_vector_hint'.tr(),
  'both' => 'search_type_both_hint'.tr(),
  _ => 'search_type_keys_hint'.tr(),
};

/// Opens the search-type picker. Shared by the lorebook list and the
/// Embeddings screen, so both apply a pick the same way.
void showLorebookSearchTypeSheet(
  BuildContext context,
  WidgetRef ref, {
  required String current,
}) {
  showLorebookOptionSheet<String>(
    context,
    title: 'label_search_type'.tr(),
    current: current,
    options: [
      for (final type in const ['keyword', 'vector', 'both'])
        LorebookOption(
          type,
          lorebookSearchTypeLabel(type),
          hint: lorebookSearchTypeHint(type),
        ),
    ],
    onSelect: (type) => selectLorebookSearchType(context, ref, type),
  );
}

/// A vector mode is only kept when there is a working embedding connection
/// to run it on. Without one it would silently behave as keyword search, so
/// the mode goes back to keys and the user is pointed at the setup instead.
Future<void> selectLorebookSearchType(
  BuildContext context,
  WidgetRef ref,
  String type,
) async {
  if (type == 'keyword') {
    updateLorebookSettings(
      ref,
      ref.read(lorebookSettingsProvider).copyWith(searchType: type),
    );
    return;
  }
  final ready = await ensureVectorsReady(context, ref);
  if (!context.mounted) return;
  final current = ref.read(lorebookSettingsProvider);
  if (!ready) {
    if (current.searchType != 'keyword') {
      updateLorebookSettings(ref, current.copyWith(searchType: 'keyword'));
    }
    return;
  }
  updateLorebookSettings(ref, current.copyWith(searchType: type));
  if (current.autoIndexVectors) {
    unawaited(ref.read(lorebookAutoIndexerProvider.notifier).scheduleAll());
  }
}
