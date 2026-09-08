import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/studio_feature_provider.dart';
import '../../../shared/shell/nav_height_provider.dart';
import '../../../shared/widgets/glaze_scaffold.dart';
import '../../../shared/widgets/menu_group.dart';
import '../providers/extensions_settings_provider.dart';

/// Experimental Features screen (Settings → Experimental Features).
///
/// Master on/off switches for opt-in, still-maturing features. Turning a
/// feature off here disables it everywhere in chat and removes its card from
/// the magic drawer (Quick Access / Tools); turning it on surfaces it again.
class ExtensionsScreen extends ConsumerWidget {
  const ExtensionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bottomPad = ref.watch(navHeightProvider) + 20;
    final extEnabled = ref.watch(
      extensionsSettingsProvider.select((s) => s.enabled),
    );
    final studioEnabled = ref.watch(studioFeatureEnabledProvider);

    return GlazeScaffold(
      title: 'experimental_features_title'.tr(),
      onBack: () => context.pop(),
      body: ListView(
        padding: EdgeInsets.fromLTRB(0, 12, 0, bottomPad),
        children: [
          MenuGroup(
            header: 'experimental_features_header'.tr(),
            items: [
              MenuSwitchItem(
                label: 'ext_blocks_title'.tr(),
                description: 'ext_blocks_hint'.tr(),
                value: extEnabled,
                onChanged: (v) =>
                    ref.read(extensionsSettingsProvider.notifier).setEnabled(v),
              ),
              MenuSwitchItem(
                label: 'menu_studio'.tr(),
                description: 'studio_hint'.tr(),
                value: studioEnabled,
                onChanged: (v) => ref
                    .read(studioFeatureEnabledProvider.notifier)
                    .setEnabled(v),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
