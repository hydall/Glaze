import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../../core/platform/haptics.dart';

/// The app's switch, tinted with the active theme's accent.
///
/// Extracted from [MenuSwitchItem] so a switch outside a menu row — a sheet
/// header's master toggle, for one — is the same control rather than a stock
/// Material one next to it.
class GlazeSwitch extends StatelessWidget {
  const GlazeSwitch({required this.value, required this.onChanged, super.key});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: value,
      onChanged: onChanged == null
          ? null
          : (v) {
              Haptics.selectionClick();
              onChanged!(v);
            },
      activeThumbColor: context.cs.primary,
      activeTrackColor: context.cs.primary.withValues(alpha: 0.5),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : context.cs.outlineVariant,
      ),
    );
  }
}
