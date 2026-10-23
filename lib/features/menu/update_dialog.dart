import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/platform/desktop_window.dart' show closeDesktopApp;
import '../../core/services/installer_update/installer_updater.dart';
import '../../core/services/update_check_service.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_action_button.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/menu_group.dart';

/// Outcome of the update sheet. [dontRemind] reflects the "don't remind me
/// about this build" toggle and is independent of which button closed it.
class UpdateDialogResult {
  final bool openedActions;
  final bool dontRemind;

  const UpdateDialogResult({
    required this.openedActions,
    required this.dontRemind,
  });
}

/// "Update available" bottom sheet. Lists what changed — release notes on
/// `stable`, commit subjects since the installed build elsewhere — and offers
/// to open the page where the artifacts live: the release, or the Actions run.
/// On Windows, a release that carries the installer is offered as an
/// in-place update instead: download, verify, run the installer, quit.
///
/// Returns the [UpdateDialogResult], or `null` when dismissed via the backdrop
/// or drag handle.
Future<UpdateDialogResult?> showUpdateDialog(
  BuildContext context,
  UpdateInfo info,
) {
  final isRelease = info.source == UpdateSource.release;
  return GlazeBottomSheet.show<UpdateDialogResult>(
    context,
    title: isRelease
        ? 'update_release_available_title'.tr()
        : 'update_available_title'.tr(),
    child: _UpdateSheetBody(info: info),
  );
}

class _UpdateSheetBody extends StatefulWidget {
  final UpdateInfo info;

  const _UpdateSheetBody({required this.info});

  @override
  State<_UpdateSheetBody> createState() => _UpdateSheetBodyState();
}

class _UpdateSheetBodyState extends State<_UpdateSheetBody> {
  bool _dontRemind = false;

  /// Progress label while installing; null when idle.
  String? _installStatus;
  CancelToken? _cancel;

  late final InstallerUpdater _updater = InstallerUpdater(
    owner: UpdateCheckService.owner,
    repo: UpdateCheckService.repo,
  );

  UpdateInfo get info => widget.info;

  bool get _canInstall => Platform.isWindows && info.installer != null;

  /// Checked once: whether the update can run silently over this copy.
  late final bool _installedBySetup = _updater.isInstalledBySetup;

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _install() async {
    final asset = info.installer;
    if (asset == null || _installStatus != null) return;
    final cancel = _cancel = CancelToken();
    setState(
      () =>
          _installStatus = 'update_downloading'.tr(namedArgs: {'percent': '0'}),
    );
    var lastPercent = -1;
    try {
      final file = await _updater.download(
        asset,
        cancelToken: cancel,
        onProgress: (received, total) {
          final percent = total > 0 ? (received * 100 ~/ total) : 0;
          if (percent == lastPercent || !mounted) return;
          lastPercent = percent;
          setState(
            () => _installStatus = 'update_downloading'.tr(
              namedArgs: {'percent': '$percent'},
            ),
          );
          if (received >= total) {
            setState(() => _installStatus = 'update_verifying'.tr());
          }
        },
      );
      if (!mounted) return;
      setState(() => _installStatus = 'update_starting_installer'.tr());
      await _updater.launch(file, silent: _installedBySetup);
      // The installer replaces the files under a running Glaze only after it
      // has closed it; leaving on our own is quicker and records a clean exit.
      await closeDesktopApp();
    } on InstallerUpdateException catch (e) {
      debugPrint('[update] $e');
      if (!mounted) return;
      setState(() => _installStatus = null);
      GlazeToast.show(context, switch (e.error) {
        InstallerUpdateError.download => 'update_install_failed_download'.tr(),
        InstallerUpdateError.verification =>
          'update_install_failed_verify'.tr(),
        InstallerUpdateError.launch => 'update_install_failed_launch'.tr(),
      }, isError: true);
    } catch (e) {
      // Cancelled because the sheet closed, or something unforeseen: either
      // way nothing was run.
      debugPrint('[update] install aborted: $e');
      if (mounted) setState(() => _installStatus = null);
    }
  }

  Future<void> _openActions() async {
    final uri = Uri.parse(info.url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _close({required bool openedActions}) {
    Navigator.pop(
      context,
      UpdateDialogResult(openedActions: openedActions, dontRemind: _dontRemind),
    );
  }

  String _formatDate(DateTime utc) {
    final local = utc.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final meta = info.label.isNotEmpty
        ? '${info.label} · ${_formatDate(info.createdAt)}'
        : _formatDate(info.createdAt);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            meta,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          if (info.notes.isNotEmpty) ...[
            Text(
              'update_changes_header'.tr(),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final note in info.notes) _CommitLine(text: note),
                  if (info.extraNotes > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, left: 13),
                      child: Text(
                        'update_more_commits'.tr(
                          namedArgs: {'count': '${info.extraNotes}'},
                        ),
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ] else
            Text(
              'update_no_commit_list'.tr(),
              style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
            ),
          const SizedBox(height: 12),
          _DontRemindToggle(
            value: _dontRemind,
            onChanged: (v) => setState(() => _dontRemind = v),
          ),
          if (_canInstall) ...[
            const SizedBox(height: 8),
            Text(
              _installedBySetup
                  ? 'update_install_restart_hint'.tr()
                  : 'update_install_portable_hint'.tr(),
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: GlazeActionButton(
                  icon: Icons.schedule_rounded,
                  label: 'update_later'.tr(),
                  onTap: () => _close(openedActions: false),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _canInstall
                    ? GlazeActionButton(
                        icon: Icons.download_rounded,
                        label: _installStatus ?? 'update_install'.tr(),
                        tone: GlazeActionTone.primary,
                        busy: _installStatus != null,
                        onTap: _install,
                      )
                    : GlazeActionButton(
                        icon: Icons.open_in_new_rounded,
                        label: info.source == UpdateSource.release
                            ? 'update_open_release'.tr()
                            : 'update_open_actions'.tr(),
                        tone: GlazeActionTone.primary,
                        onTap: () {
                          _openActions();
                          _close(openedActions: true);
                        },
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DontRemindToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _DontRemindToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return MenuSwitchItem(
      label: 'update_dont_remind'.tr(),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _CommitLine extends StatelessWidget {
  final String text;

  const _CommitLine({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 8),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.7),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: cs.onSurface.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
