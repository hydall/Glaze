import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/build_watermark_provider.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import 'settings_highlight.dart';

/// "Show build info" switch in Settings → Appearance.
///
/// Turning it on is instant. Turning it off asks first: the watermark is what
/// tells support which version a screenshot came from, and the sheet says so
/// before it goes away.
class BuildWatermarkToggle extends ConsumerWidget {
  final String? highlightId;

  const BuildWatermarkToggle({super.key, required this.highlightId});

  static const settingId = 'show_build_watermark';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return highlightIf(
      settingId,
      highlightId,
      MenuSwitchItem(
        label: 'menu_show_build_watermark'.tr(),
        description: 'desc_show_build_watermark'.tr(),
        // Stored as "hide", shown as "show", like the tooltips switch.
        value: !ref.watch(hideBuildWatermarkProvider),
        onChanged: (show) async {
          if (!show && !await _confirmHide(context)) return;
          await ref.read(hideBuildWatermarkProvider.notifier).set(!show);
        },
      ),
    );
  }

  Future<bool> _confirmHide(BuildContext context) async {
    var confirmed = false;
    await GlazeBottomSheet.show<void>(
      context,
      title: 'build_watermark_hide_title'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.bug_report_outlined,
        description: 'build_watermark_hide_warning'.tr(),
        buttonText: 'build_watermark_hide_action'.tr(),
        onButtonTap: () {
          confirmed = true;
          Navigator.of(context, rootNavigator: true).pop();
        },
      ),
    );
    return confirmed;
  }
}
