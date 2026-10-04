import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../features/lorebooks/lorebook_list_screen.dart';
import '../../../features/personas/persona_list_screen.dart';
import '../../../features/presets/preset_list_screen.dart';
import '../../../features/regex/regex_sheet.dart';
import '../../../features/settings/api_settings_screen.dart';
import 'sidebar_sheet_provider.dart';

/// One entry of the desktop right sidebar's tool strip.
///
/// Single source of truth for the five tools the strip offers, shared by the
/// strip itself and by the Tools hub rendered underneath it, so the two cannot
/// list different things or open different screens.
class SidebarTool {
  final String id;
  final String Function() label;
  final IconData icon;
  final WidgetBuilder builder;

  const SidebarTool({
    required this.id,
    required this.label,
    required this.icon,
    required this.builder,
  });

  SidebarPanel get panel => SidebarPanel(id: id, builder: builder);
}

final List<SidebarTool> sidebarTools = [
  SidebarTool(
    id: 'personas',
    label: () => 'tab_personas'.tr(),
    icon: Icons.person_outline_rounded,
    builder: (_) => const PersonaListScreen(startExpanded: true),
  ),
  SidebarTool(
    id: 'presets',
    label: () => 'tab_presets'.tr(),
    icon: Icons.description_outlined,
    builder: (_) => const PresetListScreen(startExpanded: true),
  ),
  SidebarTool(
    id: 'api',
    label: () => 'tab_api'.tr(),
    icon: Icons.cloud_outlined,
    builder: (_) => const ApiSettingsScreen(startExpanded: true),
  ),
  SidebarTool(
    id: 'lorebooks',
    label: () => 'menu_lorebooks'.tr(),
    icon: Icons.menu_book_outlined,
    builder: (_) => const LorebookListScreen(startExpanded: true),
  ),
  SidebarTool(
    id: 'regex',
    label: () => 'menu_regex'.tr(),
    icon: Icons.code_rounded,
    builder: (_) => const RegexSheet(startExpanded: true),
  ),
];

SidebarPanel sidebarToolPanel(String id) =>
    sidebarTools.firstWhere((t) => t.id == id).panel;
