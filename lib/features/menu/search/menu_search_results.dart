import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/menu_group.dart';
import 'menu_search_entry.dart';

/// Renders More-tab search hits grouped by the screen they live on, so the
/// group header doubles as the path the user would have walked to get there.
class MenuSearchResults extends StatelessWidget {
  final List<MenuSearchEntry> results;
  final EdgeInsets padding;
  final ScrollController? controller;

  /// What tapping a hit does. Defaults to the entry's own navigation; the
  /// settings screen overrides it to flash a row it already shows.
  final void Function(MenuSearchEntry entry)? onTap;

  const MenuSearchResults({
    super.key,
    required this.results,
    required this.padding,
    this.controller,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return Padding(
        padding: padding,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.only(top: 48),
            child: Text(
              'search_no_results'.tr(),
              style: TextStyle(
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.6),
                fontSize: 15,
              ),
            ),
          ),
        ),
      );
    }

    // Groups keep insertion order, so the screen holding the best hit comes
    // first and the ranking inside each group is preserved.
    final grouped = <String, List<MenuSearchEntry>>{};
    for (final entry in results) {
      grouped.putIfAbsent(entry.breadcrumbLabel, () => []).add(entry);
    }

    return ListView(
      controller: controller,
      padding: padding,
      children: [
        for (final group in grouped.entries)
          MenuGroup(
            header: group.key,
            headerVariant: MenuGroupHeaderVariant.accentCaps,
            items: [
              for (final entry in group.value)
                MenuItem(
                  icon: entry.icon,
                  label: entry.title,
                  subtitle: entry.description,
                  trailing: const Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: Color(0xFF99A2AD),
                  ),
                  onTap: () =>
                      onTap != null ? onTap!(entry) : entry.open(context),
                ),
            ],
          ),
      ],
    );
  }
}
