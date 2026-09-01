import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_scaffold.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../core/platform/haptics.dart';
import '../../../shared/theme/app_colors.dart';
import '../../settings/app_settings_provider.dart';
import '../janitor_account_provider.dart';
import '../saucepan_account_provider.dart';
import '../third_party_providers_provider.dart';
import 'janitor_login_sheet.dart';
import 'janitor_source_settings.dart';
import 'saucepan_login_sheet.dart';

/// Opens the Third-Party providers screen as a full-screen pushed route on the
/// root navigator, so it works identically from the menu and from the catalog
/// provider picker (which live in different shell branches).
Future<void> openThirdPartyProvidersScreen(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => const ThirdPartyProvidersScreen()),
  );
}

/// Lists the five third-party sources (JanitorAI, Janny, Datacat, Chub,
/// Saucepan), each as a group that can be toggled on/off. Disabling a group
/// hides that provider from the catalog and collapses its per-provider settings
/// (e.g. the account login for JanitorAI and Saucepan).
class ThirdPartyProvidersScreen extends ConsumerWidget {
  const ThirdPartyProvidersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final disabled = ref.watch(thirdPartyProvidersProvider);
    final catalogEnabled = ref.watch(catalogMasterEnabledProvider);
    final topPad = MediaQuery.of(context).padding.top + 74.0;
    final bottomPad = MediaQuery.of(context).padding.bottom + 20.0;

    return GlazeScaffold(
      title: 'third_party_providers_title'.tr(),
      showBackground: true,
      extendBodyBehindHeader: true,
      // Pushed as a raw MaterialPageRoute, so pop this route directly. Using
      // maybePop() here would be blocked by GlazeScaffold's PopScope
      // (canPop == false on non-iOS) and recurse back into onBack → crash.
      onBack: () => Navigator.of(context).pop(),
      body: ListView(
        padding: EdgeInsets.fromLTRB(0, topPad + 8, 0, bottomPad),
        children: [
          // Master switch: turning the catalog off hides the Discover tab
          // entirely, leaving only "My Characters".
          MenuGroup(
            header: 'third_party_catalog_title'.tr(),
            headerIcon: Icons.public_rounded,
            description: 'third_party_catalog_desc'.tr(),
            headerTrailing: _GroupSwitch(
              value: catalogEnabled,
              onChanged: (v) =>
                  ref.read(catalogMasterEnabledProvider.notifier).setEnabled(v),
            ),
            items: const [],
          ),
          for (final p in ThirdPartyProvider.values)
            _providerGroup(context, ref, p, enabled: !disabled.contains(p)),
        ],
      ),
    );
  }

  Widget _providerGroup(
    BuildContext context,
    WidgetRef ref,
    ThirdPartyProvider p, {
    required bool enabled,
  }) {
    return MenuGroup(
      header: _label(p),
      headerIcon: _icon(p),
      description: _description(p),
      headerTrailing: _GroupSwitch(
        value: enabled,
        onChanged: (v) =>
            ref.read(thirdPartyProvidersProvider.notifier).setEnabled(p, v),
      ),
      items: [
        // Per-provider settings are only shown while the group is enabled.
        if (enabled) ..._settingsFor(context, ref, p),
      ],
    );
  }

  List<Widget> _settingsFor(
    BuildContext context,
    WidgetRef ref,
    ThirdPartyProvider p,
  ) {
    switch (p) {
      case ThirdPartyProvider.janitor:
        final account = ref.watch(janitorAccountProvider);
        final settings = ref.watch(appSettingsProvider).value;
        return [
          MenuItem(
            icon: Icons.person_outline_rounded,
            label: 'janitor_login_menu'.tr(),
            subtitle: account.isLoggedIn
                ? 'janitor_login_menu_logged_in'.tr(
                    namedArgs: {'name': account.userName!},
                  )
                : 'janitor_login_menu_logged_out'.tr(),
            onTap: () => openJanitorAccountSheet(context, ref),
          ),
          if (settings != null)
            ...janitorSourceMenuItems(context, ref, settings),
        ];
      case ThirdPartyProvider.saucepan:
        final account = ref.watch(saucepanAccountProvider);
        return [
          MenuItem(
            icon: Icons.ramen_dining_outlined,
            label: 'Saucepan account',
            subtitle: account.isLoggedIn
                ? (account.handle != null
                      ? 'Logged in as ${account.handle}'
                      : 'Logged in')
                : 'Log in for local companion extraction',
            onTap: () => openSaucepanAccountSheet(context, ref),
          ),
        ];
      case ThirdPartyProvider.janny:
      case ThirdPartyProvider.datacat:
      case ThirdPartyProvider.chub:
        // No dedicated settings — the group is just an enable/disable toggle.
        return const [];
    }
  }

  String _label(ThirdPartyProvider p) => switch (p) {
    ThirdPartyProvider.janitor => 'JanitorAI',
    ThirdPartyProvider.janny => 'Janny',
    ThirdPartyProvider.datacat => 'Datacat',
    ThirdPartyProvider.chub => 'Chub',
    ThirdPartyProvider.saucepan => 'Saucepan',
  };

  IconData _icon(ThirdPartyProvider p) => switch (p) {
    ThirdPartyProvider.janitor => Icons.cleaning_services_outlined,
    ThirdPartyProvider.janny => Icons.auto_awesome_outlined,
    ThirdPartyProvider.datacat => Icons.pets_outlined,
    ThirdPartyProvider.chub => Icons.explore_outlined,
    ThirdPartyProvider.saucepan => Icons.ramen_dining_outlined,
  };

  String _description(ThirdPartyProvider p) => switch (p) {
    ThirdPartyProvider.janitor => 'third_party_janitor_desc'.tr(),
    ThirdPartyProvider.janny => 'third_party_janny_desc'.tr(),
    ThirdPartyProvider.datacat => 'third_party_datacat_desc'.tr(),
    ThirdPartyProvider.chub => 'third_party_chub_desc'.tr(),
    ThirdPartyProvider.saucepan => 'third_party_saucepan_desc'.tr(),
  };
}

/// Compact switch used in a [MenuGroup] header to enable/disable the group.
class _GroupSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _GroupSwitch({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: value,
      onChanged: (v) {
        Haptics.selectionClick();
        onChanged(v);
      },
      activeThumbColor: context.cs.primary,
      activeTrackColor: context.cs.primary.withValues(alpha: 0.5),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : context.cs.outlineVariant,
      ),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
