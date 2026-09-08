import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';

/// A single choice in [showLorebookOptionSheet].
class LorebookOption<T> {
  final T value;
  final String label;

  const LorebookOption(this.value, this.label);
}

/// Port of Vue `openOptionSelector` — a bottom sheet of mutually exclusive
/// options with a check mark on the currently selected one. On tap, the sheet
/// closes and [onSelect] fires with the chosen value.
Future<void> showLorebookOptionSheet<T>(
  BuildContext context, {
  required String title,
  required List<LorebookOption<T>> options,
  required T current,
  required ValueChanged<T> onSelect,
}) {
  return GlazeBottomSheet.show<void>(
    context,
    title: title,
    items: options.map((opt) {
      final selected = opt.value == current;
      return BottomSheetItem(
        label: opt.label,
        icon: selected ? Icons.check : null,
        iconColor: selected ? context.cs.primary : null,
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          onSelect(opt.value);
        },
      );
    }).toList(),
  );
}
