import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/menu_group.dart';
import '../../../memory/controllers/memory_book_controller.dart';

/// The current memory configuration, collapsed to one disclosure row.
///
/// Replaces the hero card and the `•`-joined settings line that used to sit
/// above the tabs: the line packed thirteen fields into a 12 px subtitle that
/// ellipsised at the third, and it read the same title as the tab the user was
/// already on. Collapsed it costs one row; opened it is a plain label/value
/// list, so a value can be read rather than decoded.
class MemoryBooksConfigSection extends StatelessWidget {
  final List<MemoryConfigRow> rows;

  /// Opens the generation settings — the rows are read-only, and this is the
  /// one affordance that changes them.
  final VoidCallback onOpenSettings;

  /// Shown on the disclosure row itself, so the two values most likely to be
  /// checked are readable without opening anything.
  final String modeLabel;
  final String modelLabel;

  const MemoryBooksConfigSection({
    super.key,
    required this.rows,
    required this.onOpenSettings,
    required this.modeLabel,
    required this.modelLabel,
  });

  @override
  Widget build(BuildContext context) {
    return MenuCollapsibleSection(
      label: '${'memory_books_config_title'.tr()} · $modeLabel · $modelLabel',
      children: [
        MenuGroup(
          items: [
            for (final row in rows)
              MenuItem(
                label: row.label,
                value: row.value,
                // Read-only: every one of these is owned by the settings
                // sheet, and a row that edited in place would give the sheet
                // two sources of truth to reconcile on save.
                onTap: onOpenSettings,
              ),
            MenuItem(
              icon: Icons.tune_rounded,
              label: 'memory_books_settings_title'.tr(),
              trailing: Icon(
                Icons.chevron_right,
                size: 22,
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              onTap: onOpenSettings,
            ),
          ],
        ),
      ],
    );
  }
}
