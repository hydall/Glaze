import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_stepper_sheet.dart';
import '../../../shared/widgets/glaze_switch.dart';
import '../../settings/app_settings_provider.dart';
import '../chub_account_provider.dart';
import '../janitor_account_provider.dart';
import '../third_party_providers_provider.dart';
import 'chub_login_sheet.dart';
import 'janitor_login_sheet.dart';
import 'provider_logo.dart';

/// Persisted flag so the catalog explainer is shown at most once ever.
const catalogOnboardingShownKey = 'catalog_onboarding_shown';

/// In-memory guard so the (async) check fires at most once per app session,
/// regardless of how many times the catalog body rebuilds.
bool _catalogOnboardingCheckStarted = false;

/// Shows the catalog explainer the very first time the Discover tab is opened.
/// Marks it seen up front so a dismissed or half-finished run never reappears.
Future<void> maybeShowCatalogOnboarding(BuildContext context) async {
  if (_catalogOnboardingCheckStarted) return;
  _catalogOnboardingCheckStarted = true;

  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(catalogOnboardingShownKey) ?? false) return;
  await prefs.setBool(catalogOnboardingShownKey, true);
  if (!context.mounted) return;
  await showCatalogOnboarding(context);
}

/// Opens the catalog explainer as a dismissible bottom sheet.
Future<void> showCatalogOnboarding(BuildContext context) {
  return GlazeBottomSheet.show<void>(
    context,
    isDismissible: true,
    child: const CatalogOnboardingSheet(),
  );
}

/// Re-opens the explainer on demand (Content providers → Catalog guide).
Future<void> replayCatalogOnboarding(BuildContext context) =>
    showCatalogOnboarding(context);

// ---------------------------------------------------------------------------
// Sheet
// ---------------------------------------------------------------------------

/// A short, in-context walkthrough of the catalog: what sources Glaze can read
/// from, how it pulls them, and the two logins that unlock the rest — the
/// JanitorAI source choice and the Chub account needed for NSFL.
///
/// The pages are assembled into a [GlazeStepperSheet], so which steps appear
/// follows the choices made along the way: the NSFL step only when Chub is on,
/// the JanitorAI steps only when JanitorAI is on, and the login step only for
/// Local extraction.
class CatalogOnboardingSheet extends ConsumerWidget {
  const CatalogOnboardingSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final disabled = ref.watch(thirdPartyProvidersProvider);
    final settings = ref.watch(appSettingsProvider).value ?? const AppSettings();
    final chub = !disabled.contains(ThirdPartyProvider.chub);
    final janitor = !disabled.contains(ThirdPartyProvider.janitor);

    return GlazeStepperSheet(
      onFinish: () => Navigator.of(context, rootNavigator: true).pop(),
      backLabel: 'catalog_onboarding_back'.tr(),
      skipLabel: 'catalog_onboarding_skip'.tr(),
      nextLabel: 'catalog_onboarding_next'.tr(),
      doneLabel: 'catalog_onboarding_start'.tr(),
      steps: [
        GlazeStepperStep(
          leading: const _IconBubble(icon: Icons.travel_explore_rounded),
          title: 'catalog_onboarding_welcome_title'.tr(),
          body: 'catalog_onboarding_welcome_body'.tr(),
          content: const _IntroProviders(),
        ),
        GlazeStepperStep(
          title: 'catalog_onboarding_sources_title'.tr(),
          body: 'catalog_onboarding_sources_body'.tr(),
          content: const _ProviderToggles(),
        ),
        if (chub)
          GlazeStepperStep(
            accent: true,
            title: 'catalog_onboarding_chub_title'.tr(),
            body: 'catalog_onboarding_chub_body'.tr(),
            content: const _ChubAction(),
          ),
        if (janitor)
          GlazeStepperStep(
            accent: true,
            title: 'catalog_onboarding_janitor_title'.tr(),
            body: 'catalog_onboarding_janitor_body'.tr(),
            content: const _JanitorSourceChoices(),
          ),
        if (janitor && settings.janitorSource == ExtractionSource.local)
          GlazeStepperStep(
            accent: true,
            title: 'catalog_onboarding_janitor_login_title'.tr(),
            body: 'catalog_onboarding_janitor_login_body'.tr(),
            content: const _JanitorLoginAction(),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Step content
// ---------------------------------------------------------------------------

/// The four browse providers' marks, under the welcome copy.
class _IntroProviders extends StatelessWidget {
  const _IntroProviders();

  @override
  Widget build(BuildContext context) {
    const providers = [
      ThirdPartyProvider.janitor,
      ThirdPartyProvider.janny,
      ThirdPartyProvider.chub,
      ThirdPartyProvider.datacat,
    ];
    return Row(
      children: [
        for (final p in providers)
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: ProviderLogo(provider: p, size: 30),
          ),
      ],
    );
  }
}

/// Which catalogs to switch on. Each row is the same feature the
/// content-providers screen exposes, with that screen's own description, so the
/// two places describe a source in exactly one wording.
class _ProviderToggles extends ConsumerWidget {
  const _ProviderToggles();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final disabled = ref.watch(thirdPartyProvidersProvider);
    // The four browse providers, in the same order the settings screen lists
    // them — Saucepan has no catalog feed and is not offered here.
    final providers = ThirdPartyProvider.values
        .where((p) => p.catalogProvider != null)
        .toList(growable: false);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final provider in providers) ...[
          _ProviderToggleRow(
            provider: provider,
            name: _providerLabel(provider),
            description: _providerDescription(provider),
            enabled: !disabled.contains(provider),
            onChanged: (v) => ref
                .read(thirdPartyProvidersProvider.notifier)
                .setEnabled(provider, v),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// Display name of a browse provider, from the same keys the catalog picker
/// uses.
String _providerLabel(ThirdPartyProvider p) => switch (p) {
  ThirdPartyProvider.janitor => 'catalog_provider_janitor_label'.tr(),
  ThirdPartyProvider.janny => 'catalog_provider_janny_label'.tr(),
  ThirdPartyProvider.datacat => 'catalog_provider_datacat_label'.tr(),
  ThirdPartyProvider.chub => 'catalog_provider_chub_label'.tr(),
  ThirdPartyProvider.saucepan => 'Saucepan',
};

/// The content-providers screen's own description of [p].
String _providerDescription(ThirdPartyProvider p) => switch (p) {
  ThirdPartyProvider.janitor => 'third_party_janitor_desc'.tr(),
  ThirdPartyProvider.janny => 'third_party_janny_desc'.tr(),
  ThirdPartyProvider.datacat => 'third_party_datacat_desc'.tr(),
  ThirdPartyProvider.chub => 'third_party_chub_desc'.tr(),
  ThirdPartyProvider.saucepan => 'third_party_saucepan_desc'.tr(),
};

/// Where JanitorAI cards, definitions and lorebooks come from. Picking Local
/// adds the login step right after this one.
class _JanitorSourceChoices extends ConsumerWidget {
  const _JanitorSourceChoices();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider).value ?? const AppSettings();
    final source = settings.janitorSource;

    void select(ExtractionSource value) {
      if (value == source) return;
      ref
          .read(appSettingsProvider.notifier)
          .save(settings.copyWith(janitorSource: value));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SourceOption(
          title: 'janitor_source_datacat'.tr(),
          description: 'janitor_source_datacat_hint'.tr(),
          iconWidget: ProviderLogo(
            provider: ThirdPartyProvider.datacat,
            size: 22,
          ),
          selected: source == ExtractionSource.datacat,
          onTap: () => select(ExtractionSource.datacat),
        ),
        const SizedBox(height: 10),
        _SourceOption(
          title: 'janitor_source_local'.tr(),
          description: 'janitor_source_local_hint'.tr(),
          icon: Icons.devices_rounded,
          selected: source == ExtractionSource.local,
          onTap: () => select(ExtractionSource.local),
        ),
      ],
    );
  }
}

/// The step that follows the source choice when Local was picked: ask for the
/// JanitorAI session that local extraction reads through.
class _JanitorLoginAction extends ConsumerWidget {
  const _JanitorLoginAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(janitorAccountProvider);
    if (account.isLoggedIn) {
      return _SignedInRow(
        label: 'janitor_login_menu_logged_in'.tr(
          namedArgs: {'name': account.userName ?? ''},
        ),
      );
    }
    return GlazeActionButton(
      icon: Icons.login_rounded,
      label: 'janitor_login_button'.tr(),
      tone: GlazeActionTone.primary,
      expand: true,
      onTap: () => showJanitorLoginSheet(context),
    );
  }
}

/// The NSFL unlock: a Chub login, then the NSFL switch for a signed-in account.
class _ChubAction extends ConsumerWidget {
  const _ChubAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chub = ref.watch(chubAccountProvider);
    if (!chub.isLoggedIn) {
      return GlazeActionButton(
        icon: Icons.login_rounded,
        label: 'catalog_onboarding_chub_login'.tr(),
        tone: GlazeActionTone.primary,
        expand: true,
        onTap: () => showChubLoginSheet(context),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SignedInRow(label: 'chub_login_menu_logged_in'.tr()),
        const SizedBox(height: 6),
        _SwitchRow(
          title: 'catalog_filter_nsfl'.tr(),
          description: 'chub_nsfl_account_hint'.tr(),
          value: chub.nsfl,
          onChanged: (v) => ref.read(chubAccountProvider.notifier).setNsfl(v),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _IconBubble extends StatelessWidget {
  final IconData icon;
  const _IconBubble({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: context.cs.primary.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 36, color: context.cs.primary),
    );
  }
}

class _ProviderToggleRow extends StatelessWidget {
  final ThirdPartyProvider provider;
  final String name;
  final String description;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _ProviderToggleRow({
    required this.provider,
    required this.name,
    required this.description,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: ProviderLogo(provider: provider, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: GlazeSwitch(value: enabled, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}

class _SourceOption extends StatelessWidget {
  final IconData? icon;
  final Widget? iconWidget;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  const _SourceOption({
    this.icon,
    this.iconWidget,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = context.cs.primary;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? accent : Colors.white.withValues(alpha: 0.1),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Center(
                child: iconWidget ??
                    Icon(icon, size: 22, color: context.cs.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 13,
                      color: context.cs.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 22,
              color: selected ? accent : context.cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _SignedInRow extends StatelessWidget {
  final String label;
  const _SignedInRow({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.cs.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_rounded,
            size: 20,
            color: context.cs.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 14, color: context.cs.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GlazeSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
