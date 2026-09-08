import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app.dart';
import '../../core/services/backup/backup_cancel.dart';
import '../../core/services/onboarding_service.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/sheet_view.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import 'backup_provider.dart';

class BackupScreen extends ConsumerStatefulWidget {
  final bool fromOnboarding;
  const BackupScreen({super.key, this.fromOnboarding = false});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  static const int _totalStages = 5;

  bool _isExporting = false;
  bool _isImporting = false;
  bool _importComplete = false;
  bool _hasCleared = false;
  int _importStage = 0;
  String _importProgressText = '';

  bool get _isBusy => _isExporting || (_isImporting && !_importComplete);

  bool get _canCancel => _isImporting && !_hasCleared;

  void _blockClose() {
    GlazeToast.show(
      context,
      _isExporting ? 'exporting_data'.tr() : 'importing_data'.tr(),
      isError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isBusy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _blockClose();
      },
      child: SheetView(
        title: 'menu_backups'.tr(),
        showBack: true,
        fitContent: true,
        onBack: () {
          if (_isBusy) {
            _blockClose();
            return;
          }
          Navigator.of(context).maybePop();
        },
        body: Builder(
          builder: (innerContext) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            layoutBuilder: (currentChild, previousChildren) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...previousChildren,
                  ?currentChild,
                ],
              );
            },
            child: _buildContent(innerContext),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_isImporting && !_importComplete) {
      return _ProgressView(
        key: const ValueKey('progress'),
        title: 'importing_data'.tr(),
        subtitle: _importProgressText,
        progress: _importStage / _totalStages,
        canCancel: _canCancel,
        onCancel: _cancelImport,
      );
    }
    if (_importComplete) {
      return _SuccessView(
        key: const ValueKey('complete'),
        title: 'backup_success_title'.tr(),
        subtitle: 'backup_success_desc'.tr(),
        buttonText: 'btn_reload'.tr(),
        onPressed: _reloadApp,
      );
    }
    return _NormalView(
      key: const ValueKey('normal'),
      isExporting: _isExporting,
      onExport: _performExport,
      onImport: _triggerImport,
    );
  }

  Future<void> _performExport() async {
    setState(() => _isExporting = true);
    try {
      final service = await ref.read(backupServiceProvider.future);
      final path = await service.exportBackup();

      if (mounted) {
        GlazeToast.show(context, '${'msg_saved_to'.tr()} $path');
      }
    } catch (e) {
      if (mounted) {
        GlazeErrorDialog.show(context, e, prefix: 'settings_err_failed'.tr());
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  /// Extensions the picker offers, in sync with what `BackupService` still
  /// accepts. `tbk` (Tavo) is omitted while `BackupService.tavoImportEnabled`
  /// is off.
  static const List<String> _importExtensions = ['glz', 'json', 'zip'];

  Future<void> _triggerImport() async {
    final result = await FilePicker.pickFiles(
      type: Platform.isIOS ? FileType.any : FileType.custom,
      allowMultiple: false,
      allowedExtensions: Platform.isIOS ? null : _importExtensions,
    );
    if (result == null || result.files.isEmpty) return;

    final path = result.files.single.path;
    if (path == null) return;

    if (!mounted) return;
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'confirm_restore'.tr(),
      bigInfo: const BottomSheetBigInfo(
        icon: Icons.warning_amber_rounded,
        description: '', // Desc is already in title of confirm_restore
      ),
      items: [
        BottomSheetItem(
          label: 'btn_yes'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'btn_no'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    if (confirmed != true) return;

    final ext = path.split('.').last.toLowerCase();

    setState(() {
      _isImporting = true;
      _importComplete = false;
      _hasCleared = false;
      _importStage = 0;
      _importProgressText = 'backup_progress_preparing'.tr();
    });

    try {
      if (_importExtensions.contains(ext)) {
        setState(() {
          _importStage = 1;
          _importProgressText = 'backup_progress_reading'.tr();
        });
        final service = await ref.read(backupServiceProvider.future);
        await service.importBackupFromFile(
          path,
          onDetected: (format) {
            // No-op for now; reserved for future format-specific UI.
            format.toString();
          },
          onProgress: (stage) {
            if (!mounted) return;
            setState(() {
              _hasCleared = true;
              _importStage = (_importStage + 1).clamp(1, _totalStages - 1);
              _importProgressText = stage;
            });
          },
        );
        if (!mounted) return;
        setState(() {
          _importStage = _totalStages;
          _importComplete = true;
        });
      } else {
        throw FormatException('Unsupported file format: .$ext');
      }
    } on ImportCancelledException {
      if (!mounted) return;
      setState(() {
        _isImporting = false;
        _importComplete = false;
        _hasCleared = false;
      });
      GlazeToast.show(
        context,
        'cancel_import_done'.tr(),
        isError: false,
      );
    } catch (e, st) {
      if (!mounted) return;
      setState(() {
        _isImporting = false;
        _importComplete = false;
        _hasCleared = false;
      });
      GlazeErrorDialog.show(context, '$e\n\n$st', prefix: 'settings_err_failed'.tr());
    }
  }

  Future<void> _cancelImport() async {
    final service = await ref.read(backupServiceProvider.future);
    service.cancelImport();
  }

  Future<void> _reloadApp() async {
    if (widget.fromOnboarding) {
      await markOnboardingComplete();
    }
    if (!mounted) return;
    final rootNav = Navigator.of(context, rootNavigator: true);
    rootNav.pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      GlazeApp.restartApp();
    });
  }
}

class _NormalView extends StatelessWidget {
  final bool isExporting;
  final VoidCallback onExport;
  final VoidCallback onImport;

  const _NormalView({
    super.key,
    required this.isExporting,
    required this.onExport,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12 + MediaQuery.paddingOf(context).top, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Section(
            title: 'menu_import'.tr(),
            children: [
              _BsButton(
                onPressed: onImport,
                icon: Icons.file_upload_outlined,
                label: 'menu_import'.tr(),
                primary: true,
              ),
              const SizedBox(height: 4),
              _Hint(
                lines: [
                  // Tavo (.tbk) is hidden while
                  // `BackupService.tavoImportEnabled` is off — the
                  // `backup_hint_import_tavo` string stays in the translations
                  // for when the format comes back.
                  _HintLine.markup('backup_hint_import_st'.tr()),
                  _HintLine.markup('backup_hint_import_glaze'.tr()),
                ],
              ),
            ],
          ),
          const _Separator(),
          _Section(
            title: 'menu_export'.tr(),
            children: [
              _BsButton(
                onPressed: isExporting ? null : onExport,
                icon: Icons.file_download_outlined,
                label: isExporting ? 'backup_progress_preparing'.tr() : 'menu_export'.tr(),
                primary: false,
                loading: isExporting,
              ),
              _Hint(
                lines: [
                  _HintLine(
                    text: 'backup_hint_export'.tr(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurfaceVariant,
              letterSpacing: 0.5,
            ),
          ),
        ),
        ...children.expand((w) => [w, const SizedBox(height: 8)]).toList()
          ..removeLast(),
      ],
    );
  }
}

class _BsButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final bool primary;
  final bool loading;

  const _BsButton({
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.primary,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = context.cs.primary;
    final bg = primary ? accent : accent.withValues(alpha: 0.1);
    final fg = primary ? Colors.white : accent;
    final disabled = onPressed == null;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onPressed,
        child: Opacity(
          opacity: disabled ? 0.7 : 1.0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (loading)
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      valueColor: AlwaysStoppedAnimation<Color>(fg),
                    ),
                  )
                else
                  Icon(icon, size: 22, color: fg),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HintLine {
  final String? bold;
  final String text;
  const _HintLine({this.bold, required this.text});

  /// Splits a localized hint that marks its lead-in with `<b>…</b>`, e.g.
  /// `<b>SillyTavern (.zip):</b> characters, presets, chats`, into the bold run
  /// and the remainder. Falls back to an unstyled line when the markup is
  /// absent.
  factory _HintLine.markup(String source) {
    final m = RegExp(r'^<b>(.*?)</b>\s*(.*)$', dotAll: true).firstMatch(source);
    if (m == null) return _HintLine(text: source);
    return _HintLine(bold: '${m.group(1)!} ', text: m.group(2)!);
  }
}

class _Hint extends StatelessWidget {
  final List<_HintLine> lines;
  const _Hint({required this.lines});

  @override
  Widget build(BuildContext context) {
    final baseStyle = TextStyle(
      fontSize: 13,
      height: 1.5,
      color: context.cs.onSurfaceVariant.withValues(alpha: 0.9),
    );

    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines
            .map(
              (l) => RichText(
                text: TextSpan(
                  style: baseStyle,
                  children: [
                    if (l.bold != null)
                      TextSpan(
                        text: l.bold,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    TextSpan(text: l.text),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Container(
        height: 1,
        color: Colors.white.withValues(alpha: 0.1),
      ),
    );
  }
}

class _ProgressView extends StatelessWidget {
  final String title;
  final String subtitle;
  final double progress;
  final bool canCancel;
  final VoidCallback onCancel;

  const _ProgressView({
    super.key,
    required this.title,
    required this.subtitle,
    required this.progress,
    required this.canCancel,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final accent = context.cs.primary;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 32 + MediaQuery.paddingOf(context).top, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation<Color>(accent),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              height: 1.5,
              color: context.cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              height: 8,
              color: Colors.white.withValues(alpha: 0.1),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TweenAnimationBuilder<double>(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
                  builder: (_, value, _) => FractionallySizedBox(
                    widthFactor: value,
                    child: Container(
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (canCancel) ...[
            const SizedBox(height: 24),
            _BsButton(
              onPressed: onCancel,
              icon: Icons.close,
              label: 'btn_cancel'.tr(),
              primary: false,
            ),
          ],
        ],
      ),
    );
  }
}

class _SuccessView extends StatelessWidget {
  final String title;
  final String subtitle;
  final String buttonText;
  final VoidCallback onPressed;

  const _SuccessView({
    super.key,
    required this.title,
    required this.subtitle,
    required this.buttonText,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final accent = context.cs.primary;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 32 + MediaQuery.paddingOf(context).top, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check, size: 32, color: accent),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              height: 1.5,
              color: context.cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          _BsButton(
            onPressed: onPressed,
            icon: Icons.refresh,
            label: buttonText,
            primary: true,
          ),
        ],
      ),
    );
  }
}
