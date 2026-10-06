import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
// Pinned via dependency_overrides to keep Windows builds green; see docs/BUILD_NOTES.md.
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/diagnostics/app_log.dart';
import '../../core/diagnostics/diagnostics_store.dart';
import '../../core/services/file_export_service.dart';
import '../../shared/widgets/glaze_toast.dart';

/// Getting a log or crash report off the device.
///
/// Phones get the system share sheet, which is how a report ends up in the
/// Telegram or Discord chat developers read. Desktop has no share sheet worth
/// the name, so the file is saved where the user picks instead.
abstract final class DiagnosticsShare {
  static const _shareOrigin = Rect.fromLTWH(0, 0, 1, 1);

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static Future<void> shareFile(BuildContext context, String path) async {
    // Whatever the app logged up to this moment belongs in what is sent.
    AppLog.flush();
    try {
      if (_isDesktop) {
        final saved = await FileExportService.exportFile(
          sourcePath: path,
          filename: p.basename(path),
          subfolder: 'Logs',
        );
        if (saved.isNotEmpty && context.mounted) {
          GlazeToast.show(context, 'logs_saved_to'.tr(args: [saved]));
        }
        return;
      }
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path)],
          subject: 'Glaze ${p.basename(path)}',
          sharePositionOrigin: _shareOrigin,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        GlazeToast.show(context, 'logs_share_failed'.tr(), isError: true);
      }
      AppLog.error(e, StackTrace.current, context: 'Sharing $path failed');
    }
  }

  /// Every session log and crash report in one zip.
  static Future<void> shareAll(BuildContext context) async {
    AppLog.flush();
    try {
      final zip = await DiagnosticsStore.zipAll(
        (await getTemporaryDirectory()).path,
      );
      if (!context.mounted) return;
      await shareFile(context, zip);
    } catch (e, st) {
      AppLog.error(e, st, context: 'Zipping logs failed');
      if (context.mounted) {
        GlazeToast.show(context, 'logs_share_failed'.tr(), isError: true);
      }
    }
  }

  static Future<void> copyFile(BuildContext context, String path) async {
    AppLog.flush();
    final text = await DiagnosticsStore.tail(path, maxLines: 2000);
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) GlazeToast.show(context, 'logs_copied'.tr());
  }

  static bool get canOpenFolder => _isDesktop;

  static Future<void> openFolder() async {
    final dir = await DiagnosticsStore.rootDir();
    await launchUrl(Uri.directory(dir));
  }
}
