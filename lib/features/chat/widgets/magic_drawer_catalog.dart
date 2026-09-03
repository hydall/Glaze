import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import 'magic_drawer_models.dart';

/// Every card the Tools tab knows how to show, in the order a fresh install
/// gets them.
///
/// Built on demand rather than held in a `final` list: the labels are localized
/// at construction, and a cached list would keep the strings of whatever locale
/// happened to be active the first time the drawer opened.
///
/// Lives apart from the panel because the composer's pinned row resolves tool
/// pins against the same catalog — see [ComposerPin] — and neither side should
/// own the other's copy of it.
List<MagicDrawerItemDef> buildMagicDrawerItems() => [
  MagicDrawerItemDef(
    id: 'inspector',
    label: 'prompt_inspector_title'.tr(),
    icon: Icons.travel_explore,
    category: MagicDrawerCategory.tools,
  ),
  MagicDrawerItemDef(
    id: 'memory',
    label: 'Memory',
    icon: Icons.subject,
    category: MagicDrawerCategory.session,
  ),
  MagicDrawerItemDef(
    id: 'sessions',
    label: 'history_title'.tr(),
    icon: Icons.history,
    category: MagicDrawerCategory.session,
  ),
  MagicDrawerItemDef(
    id: 'char-card',
    label: 'menu_characters'.tr(),
    icon: Icons.account_box,
    category: MagicDrawerCategory.library,
  ),
  MagicDrawerItemDef(
    id: 'lorebooks',
    label: 'label_lorebooks'.tr(),
    icon: Icons.library_books,
    category: MagicDrawerCategory.library,
  ),
  MagicDrawerItemDef(
    id: 'regex',
    label: 'menu_regex'.tr(),
    icon: Icons.code,
    category: MagicDrawerCategory.config,
  ),
  MagicDrawerItemDef(
    id: 'api',
    label: 'tab_api'.tr(),
    icon: Icons.cloud,
    category: MagicDrawerCategory.config,
  ),
  MagicDrawerItemDef(
    id: 'presets',
    label: 'tab_presets'.tr(),
    icon: Icons.description,
    category: MagicDrawerCategory.config,
  ),
  MagicDrawerItemDef(
    id: 'personas',
    label: 'menu_personas'.tr(),
    icon: Icons.manage_accounts,
    category: MagicDrawerCategory.library,
  ),
  MagicDrawerItemDef(
    id: 'image-gen',
    label: 'imggen_title'.tr(),
    icon: Icons.image,
    category: MagicDrawerCategory.tools,
  ),
  MagicDrawerItemDef(
    id: 'authors-note',
    label: 'magic_authors_notes'.tr(),
    icon: Icons.edit_note,
    category: MagicDrawerCategory.session,
  ),
  MagicDrawerItemDef(
    id: 'glossary',
    label: 'menu_glossary'.tr(),
    icon: Icons.menu_book,
    category: MagicDrawerCategory.library,
  ),
  MagicDrawerItemDef(
    id: 'ext-blocks',
    label: 'Ext Blocks',
    icon: Icons.extension_outlined,
    category: MagicDrawerCategory.config,
  ),
  MagicDrawerItemDef(
    id: 'agent-ops',
    label: 'agent_ops_title'.tr(),
    icon: Icons.smart_toy_outlined,
    category: MagicDrawerCategory.tools,
  ),
  MagicDrawerItemDef(
    id: 'card-rewriter',
    label: 'magic_card_rewriter'.tr(),
    icon: Icons.auto_fix_high_outlined,
    category: MagicDrawerCategory.tools,
  ),
];

/// The catalog entry for [id], or null when a stored layout or a pinned button
/// still names a card this build has dropped.
MagicDrawerItemDef? magicDrawerItemById(String id) {
  for (final item in buildMagicDrawerItems()) {
    if (item.id == id) return item;
  }
  return null;
}
