import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/update_check_service.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';

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

  UpdateInfo get info => widget.info;

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
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _close(openedActions: false),
                  child: Text('update_later'.tr()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () {
                    _openActions();
                    _close(openedActions: true);
                  },
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(
                    info.source == UpdateSource.release
                        ? 'update_open_release'.tr()
                        : 'update_open_actions'.tr(),
                  ),
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
    final cs = context.cs;
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.fromLTRB(12, 6, 16, 6),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: value,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => onChanged(v ?? false),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'update_dont_remind'.tr(),
                  style: TextStyle(fontSize: 14, color: cs.onSurface),
                ),
              ),
            ],
          ),
        ),
      ),
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
