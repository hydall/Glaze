import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/diagnostics/app_log.dart';
import '../../core/diagnostics/diagnostics_store.dart';
import '../../shared/shell/nav_height_provider.dart';
import '../../shared/shell/shell_header_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/menu_group.dart';
import 'crash_prompt.dart' show crashKindLabel;
import 'diagnostics_share.dart';
import 'log_viewer_screen.dart';

/// Menu → Logs & crashes: every crash report and session log on the device,
/// with a way to send each of them.
class LogsScreen extends ConsumerStatefulWidget {
  const LogsScreen({super.key});

  @override
  ConsumerState<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends ConsumerState<LogsScreen> {
  List<DiagnosticsFile>? _crashes;
  Map<String, String> _crashKinds = const {};
  List<DiagnosticsFile>? _sessions;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    await AppLog.ready;
    AppLog.flush();
    final crashes = await DiagnosticsStore.list(DiagnosticsFileKind.crash);
    final sessions = await DiagnosticsStore.list(DiagnosticsFileKind.session);
    final kinds = <String, String>{
      for (final file in crashes)
        file.path: ?await DiagnosticsStore.crashKind(file.path),
    };
    if (!mounted) return;
    setState(() {
      _crashes = crashes;
      _crashKinds = kinds;
      _sessions = sessions;
    });
  }

  bool _isCurrent(DiagnosticsFile file) => file.path == AppLog.sessionPath;

  void _openActions(DiagnosticsFile file) {
    void close(BuildContext c) => Navigator.of(c, rootNavigator: true).pop();
    GlazeBottomSheet.show<void>(
      context,
      title: file.name,
      items: [
        BottomSheetItem(
          label: 'logs_view'.tr(),
          icon: Icons.visibility_outlined,
          onTap: () {
            close(context);
            LogViewerScreen.open(context, file);
          },
        ),
        BottomSheetItem(
          label: 'logs_share'.tr(),
          icon: Icons.ios_share_rounded,
          onTap: () {
            close(context);
            DiagnosticsShare.shareFile(context, file.path);
          },
        ),
        BottomSheetItem(
          label: 'logs_copy'.tr(),
          icon: Icons.copy_rounded,
          onTap: () {
            close(context);
            DiagnosticsShare.copyFile(context, file.path);
          },
        ),
        if (!_isCurrent(file))
          BottomSheetItem(
            label: 'btn_delete'.tr(),
            icon: Icons.delete_outline_rounded,
            isDestructive: true,
            onTap: () async {
              close(context);
              await DiagnosticsStore.delete(file);
              await _reload();
            },
          ),
      ],
    );
  }

  void _confirmClear() {
    void close(BuildContext c) => Navigator.of(c, rootNavigator: true).pop();
    GlazeBottomSheet.show<void>(
      context,
      title: 'logs_clear'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_sweep_outlined,
        description: 'logs_clear_confirm'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () async {
            close(context);
            await DiagnosticsStore.clear(keep: AppLog.sessionPath);
            await _reload();
          },
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => close(context),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPad = DetachedShellHost.of(context)
        ? 0.0
        : MediaQuery.of(context).padding.top + 74.0;
    final crashes = _crashes;
    final sessions = _sessions;

    return GlazeScaffold(
      title: 'logs_title'.tr(),
      useShellHeader: true,
      headerBranchIndex: 3,
      extendBodyBehindHeader: true,
      onBack: () => context.go('/menu'),
      showBackground: false,
      body: crashes == null || sessions == null
          ? const Center(child: GlazeSpinner(size: 32))
          : ListView(
              padding: EdgeInsets.fromLTRB(
                0,
                topPad + 8,
                0,
                // A desktop window has no nav bar to clear.
                DetachedShellHost.of(context)
                    ? 16
                    : ref.watch(navHeightProvider) + 20,
              ),
              children: [
                MenuGroup(
                  description: 'logs_privacy_note'.tr(),
                  items: [
                    MenuItem(
                      icon: Icons.archive_outlined,
                      label: 'logs_share_all'.tr(),
                      subtitle: 'logs_share_all_hint'.tr(),
                      onTap: () => DiagnosticsShare.shareAll(context),
                    ),
                    if (DiagnosticsShare.canOpenFolder)
                      MenuItem(
                        icon: Icons.folder_open_outlined,
                        label: 'logs_open_folder'.tr(),
                        onTap: DiagnosticsShare.openFolder,
                      ),
                  ],
                ),
                MenuGroup(
                  header: 'logs_crashes'.tr(),
                  headerIcon: Icons.bug_report_rounded,
                  items: crashes.isEmpty
                      ? [_EmptyRow('logs_no_crashes'.tr())]
                      : [
                          for (final file in crashes)
                            MenuItem(
                              icon: Icons.error_outline_rounded,
                              label: _formatDate(file.createdAt),
                              subtitle: [
                                if (_crashKinds[file.path] case final kind?)
                                  crashKindLabel(kind),
                                _formatSize(file.bytes),
                              ].join(' · '),
                              onTap: () => _openActions(file),
                            ),
                        ],
                ),
                MenuGroup(
                  header: 'logs_sessions'.tr(),
                  headerIcon: Icons.receipt_long_rounded,
                  items: [
                    for (final file in sessions)
                      MenuItem(
                        icon: Icons.description_outlined,
                        label: _formatDate(file.createdAt),
                        subtitle: _isCurrent(file)
                            ? '${'logs_current_session'.tr()} · '
                                  '${_formatSize(file.bytes)}'
                            : _formatSize(file.bytes),
                        onTap: () => _openActions(file),
                      ),
                  ],
                ),
                MenuGroup(
                  items: [
                    MenuItem(
                      icon: Icons.delete_sweep_outlined,
                      label: 'logs_clear'.tr(),
                      onTap: _confirmClear,
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  final String text;

  const _EmptyRow(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Text(
      text,
      style: TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant),
    ),
  );
}

String _formatDate(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.day)}.${two(t.month)}.${t.year}  '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
