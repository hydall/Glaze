import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/diagnostics/app_log.dart';
import '../../core/diagnostics/crash_detector.dart';
import '../../core/navigation/router.dart' show rootNavigatorKey;
import '../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import 'diagnostics_share.dart';

/// Offers to send the report when the previous run crashed. Called from the
/// startup hooks; shows nothing on a normal launch.
Future<void> offerCrashReportOnStartup() async {
  await AppLog.ready;
  final crash = AppLog.takePendingCrash();
  if (crash == null) return;
  // Same reason as the update prompt: the startup hook sits above
  // MaterialApp, so only the root navigator has an Overlay to show on.
  final context = rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  await showCrashReportSheet(context, crash);
}

Future<void> showCrashReportSheet(BuildContext context, DetectedCrash crash) {
  void close(BuildContext sheet) =>
      Navigator.of(sheet, rootNavigator: true).pop();
  return GlazeBottomSheet.show<void>(
    context,
    title: 'crash_prompt_title'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: Icons.bug_report_outlined,
      description:
          '${crashKindLabel(crash.kind)}\n\n${'crash_prompt_body'.tr()}',
      buttonText: 'crash_prompt_share'.tr(),
      onButtonTap: () {
        close(context);
        DiagnosticsShare.shareFile(context, crash.reportPath);
      },
    ),
    items: [
      BottomSheetItem(
        label: 'crash_prompt_open_logs'.tr(),
        icon: Icons.receipt_long_outlined,
        onTap: () {
          close(context);
          goOrFloat(context, 'logs', push: true);
        },
      ),
      BottomSheetItem(
        label: 'crash_prompt_later'.tr(),
        centered: true,
        onTap: () => close(context),
      ),
    ],
  );
}

/// What the user is told about a crash of [kind] ([DetectedCrash.kind]).
String crashKindLabel(String kind) => switch (kind) {
  'CRASH' || 'INITIALIZATION_FAILURE' => 'crash_kind_exception'.tr(),
  'CRASH_NATIVE' => 'crash_kind_native'.tr(),
  'ANR' => 'crash_kind_anr'.tr(),
  'LOW_MEMORY' => 'crash_kind_memory'.tr(),
  _ => 'crash_kind_unclean'.tr(),
};
