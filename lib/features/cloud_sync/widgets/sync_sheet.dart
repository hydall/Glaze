import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/utils/time_formatter.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../sync_provider.dart';
import '../sync_models.dart';
import '../services/sync_conflict.dart';
import '../services/sync_service.dart';
import '../services/sync_controller.dart';
import 'sync_icons.dart';
import 'sync_sheet_widgets.dart';
import 'package:easy_localization/easy_localization.dart';

class SyncSheet extends ConsumerStatefulWidget {
  const SyncSheet({super.key});

  @override
  ConsumerState<SyncSheet> createState() => _SyncSheetState();
}

class _SyncSheetState extends ConsumerState<SyncSheet> {
  late final SyncController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = SyncController(ref, isMounted: () => mounted);
    _ctrl.initStateFromService();
    _ctrl.loadIncludeApiKeys().then((_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ctrl.resolveFolderIdIfNeeded().then((_) {
        if (mounted) setState(() {});
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(syncServiceProvider);
    final status = ref.watch(syncStatusProvider);
    final provider = ref.watch(syncProviderProvider);
    final connected = ref.watch(syncConnectedProvider);
    final progress = ref.watch(syncProgressProvider);
    final conflicts = ref.watch(syncConflictsProvider);
    final lastError = ref.watch(syncLastErrorProvider);
    final autoEnabled = ref.watch(syncAutoEnabledProvider);
    final service = ref.watch(syncServiceProvider).value;

    final isSyncing = status == SyncStatus.syncing || _ctrl.isWiping;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _goBack();
      },
      child: SheetView(
        title: 'menu_cloud_sync'.tr(),
        showBack: true,
        fitContent: true,
        onBack: _goBack,
        body: Builder(
          builder: (innerContext) => SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              16,
              12 + MediaQuery.paddingOf(innerContext).top,
              16,
              16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!connected) ...[
                  buildSyncSectionHeader(context, 'sync_connect_provider'.tr()),
                  const SizedBox(height: 4),
                  buildSyncProviderButton(
                    icon: const DropboxIcon(size: 22, color: Colors.white),
                    label: _ctrl.isConnecting
                        ? 'sync_connecting'.tr()
                        : 'Dropbox',
                    color: context.colors.accent,
                    onPressed: _ctrl.isConnecting || _ctrl.isConnectingGdrive
                        ? null
                        : _connectDropbox,
                  ),
                  const SizedBox(height: 8),
                  buildSyncProviderButton(
                    icon: const GDriveIcon(size: 22, color: Colors.white),
                    label: _ctrl.isConnectingGdrive
                        ? 'sync_connecting'.tr()
                        : 'Google Drive',
                    color: const Color(0xFF4285F4),
                    onPressed: _ctrl.isConnecting || _ctrl.isConnectingGdrive
                        ? null
                        : _connectGDrive,
                  ),
                  if (lastError != null) ...[
                    const SizedBox(height: 12),
                    buildSyncErrorCard(lastError),
                  ],
                ] else ...[
                  _buildConnectedCard(context, status, provider, service),
                  if (provider == SyncProvider.gdrive &&
                      _ctrl.gdriveFolderId != null)
                    _buildFolderIdRow(context),
                  if (conflicts.isNotEmpty)
                    _buildConflictBanner(context, conflicts),
                  if (_ctrl.syncResult != null)
                    buildSyncResultCard(context, _ctrl.syncResult!),
                  if ((status == SyncStatus.syncing || _ctrl.isWiping) &&
                      progress != null)
                    buildSyncProgressBar(context, progress),
                  if (lastError != null) ...[
                    const SizedBox(height: 12),
                    buildSyncErrorCard(lastError),
                  ],
                  const SizedBox(height: 16),
                  buildSyncSectionHeader(context, 'sync_manual'.tr()),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: buildSyncManualButton(
                          context: context,
                          onPressed: isSyncing ? null : () => _doSync('push'),
                          icon: Icons.cloud_upload_outlined,
                          label: 'sync_push'.tr(),
                          primary: false,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: buildSyncManualButton(
                          context: context,
                          onPressed: isSyncing ? null : () => _doSync('pull'),
                          icon: Icons.cloud_download_outlined,
                          label: 'sync_pull'.tr(),
                          primary: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  buildSyncSectionHeader(context, 'section_sync_settings'.tr()),
                  const SizedBox(height: 4),
                  _buildAutoSyncToggle(context, autoEnabled, service),
                  if (autoEnabled && service != null)
                    _buildAutoSyncThresholdRow(context, service),
                  _buildIncludeApiKeysToggle(context),
                  const SizedBox(height: 16),
                  Divider(
                    color: Colors.white.withValues(alpha: 0.1),
                    height: 1,
                  ),
                  const SizedBox(height: 16),
                  buildSyncDangerButton(
                    icon: Icons.logout_rounded,
                    label: 'sync_disconnect'.tr(),
                    onPressed: _ctrl.isDisconnecting ? null : _disconnect,
                  ),
                  const SizedBox(height: 8),
                  buildSyncDangerButton(
                    icon: Icons.delete_outline_rounded,
                    label: _ctrl.isWiping
                        ? 'sync_wiping'.tr()
                        : 'sync_wipe_cloud'.tr(),
                    onPressed: _ctrl.isWiping ? null : _wipeCloudData,
                    light: true,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConnectedCard(
    BuildContext context,
    SyncStatus status,
    SyncProvider provider,
    SyncService? service,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colors.accent.withValues(alpha: 0.05),
        border: Border.all(
          color: context.colors.accent.withValues(alpha: 0.15),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (provider == SyncProvider.dropbox)
                DropboxIcon(size: 24, color: context.colors.accent)
              else
                const GDriveIcon(size: 24, color: Color(0xFF4285F4)),
              const SizedBox(width: 8),
              Text(
                provider == SyncProvider.dropbox ? 'Dropbox' : 'Google Drive',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: context.cs.onSurface,
                ),
              ),
              const Spacer(),
              if (status == SyncStatus.syncing)
                const PulsingDot(color: Color(0xFFFF9800))
              else if (status == SyncStatus.error)
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFF3B30),
                    shape: BoxShape.circle,
                  ),
                )
              else
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Color(0xFF4CAF50),
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
          if (service?.accountInfo != null &&
              service!.accountInfo!['email'] != null) ...[
            const SizedBox(height: 6),
            Text(
              service.accountInfo!['email'] as String,
              style: TextStyle(
                fontSize: 13,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            _getStatusLabel(status, service),
            style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderIdRow(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Text(
            'sync_gdrive_folder_id'.tr(),
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _ctrl.gdriveFolderId!,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Colors.white70,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.copy, size: 16, color: Colors.white54),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _ctrl.gdriveFolderId!));
              GlazeToast.show(
                context,
                "${'sync_gdrive_folder_id'.tr()} ${'action_copy'.tr().toLowerCase()}",
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildConflictBanner(
    BuildContext context,
    List<SyncConflict> conflicts,
  ) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.05),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.15)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Colors.orangeAccent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                "${'sync_conflicts_title'.tr()} (${conflicts.length})",
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.orangeAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => _resolveAllConflicts('local'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    backgroundColor: Colors.blueAccent.withValues(alpha: 0.15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    'sync_keep_all_local'.tr(),
                    style: const TextStyle(
                      color: Colors.blueAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  onPressed: () => _resolveAllConflicts('cloud'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    backgroundColor: Colors.greenAccent.withValues(alpha: 0.15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    'sync_keep_all_cloud'.tr(),
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...conflicts.map(
            (c) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      c.name,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _resolveConflict(c, 'local'),
                    child: Text(
                      'sync_keep_local'.tr(),
                      style: const TextStyle(color: Colors.blueAccent),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _resolveConflict(c, 'cloud'),
                    child: Text(
                      'sync_keep_cloud'.tr(),
                      style: const TextStyle(color: Colors.greenAccent),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAutoSyncToggle(
    BuildContext context,
    bool autoEnabled,
    SyncService? service,
  ) {
    return GestureDetector(
      onTap: () {
        _setAutoSync(!autoEnabled);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        color: Colors.transparent,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'sync_enable_auto'.tr(),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: context.cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'sync_auto_desc'.tr(),
                    style: TextStyle(
                      fontSize: 12,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: autoEnabled,
              onChanged: _setAutoSync,
              activeThumbColor: context.colors.accent,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAutoSyncThresholdRow(BuildContext context, SyncService service) {
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      child: Row(
        children: [
          Text(
            '${'sync_every'.tr()} ',
            style: TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          buildSyncCountButton(
            icon: Icons.remove,
            onPressed: service.autoSyncMessageCount > 1
                ? () =>
                      _updateAutoSyncThreshold(service.autoSyncMessageCount - 1)
                : null,
          ),
          Container(
            width: 50,
            alignment: Alignment.center,
            child: Text(
              '${service.autoSyncMessageCount}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: context.cs.onSurface,
              ),
            ),
          ),
          buildSyncCountButton(
            icon: Icons.add,
            onPressed: service.autoSyncMessageCount < 50
                ? () =>
                      _updateAutoSyncThreshold(service.autoSyncMessageCount + 1)
                : null,
          ),
          const SizedBox(width: 8),
          Text(
            ' ${'sync_messages'.tr()}',
            style: TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildIncludeApiKeysToggle(BuildContext context) {
    return GestureDetector(
      onTap: () {
        _setIncludeApiKeys(!_ctrl.syncIncludeApiKeys);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        color: Colors.transparent,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'label_sync_include_keys'.tr(),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: context.cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'desc_sync_include_keys'.tr(),
                    style: TextStyle(
                      fontSize: 12,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: _ctrl.syncIncludeApiKeys,
              onChanged: _setIncludeApiKeys,
              activeThumbColor: context.colors.accent,
            ),
          ],
        ),
      ),
    );
  }

  void _goBack() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      context.go('/menu');
    }
  }

  String _getStatusLabel(SyncStatus status, SyncService? service) {
    if (_ctrl.isWiping) return 'sync_wiping'.tr();
    if (status == SyncStatus.syncing) return 'sync_status_syncing'.tr();
    if (status == SyncStatus.error) return 'sync_status_error'.tr();
    if (status == SyncStatus.conflict) return 'sync_status_conflict'.tr();
    if (service?.lastSyncTime != null) {
      return "${'sync_last_sync'.tr()}: ${_formatTimeAgo(service!.lastSyncTime!)}";
    }
    return 'sync_status_idle'.tr();
  }

  String _formatTimeAgo(int ts) {
    return formatTimeAgoFromMs(ts);
  }

  Future<void> _connectDropbox() async {
    setState(() {});
    final error = await _ctrl.connectDropbox();
    if (mounted) {
      setState(() {});
      if (error != null) GlazeErrorDialog.show(context, error);
    }
  }

  Future<void> _connectGDrive() async {
    setState(() {});
    final error = await _ctrl.connectGDrive();
    if (mounted) {
      setState(() {});
      if (error != null) GlazeErrorDialog.show(context, error);
    }
  }

  Future<void> _disconnect() async {
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'sync_disconnect'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.link_off_rounded,
        description: 'sync_confirm_disconnect'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'sync_disconnect'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );

    if (confirmed != true) return;

    setState(() {});
    final error = await _ctrl.disconnect();
    if (mounted) {
      setState(() {});
      if (error != null) GlazeErrorDialog.show(context, error);
    }
  }

  Future<void> _wipeCloudData() async {
    final service = ref.read(syncServiceProvider).value;
    if (service == null) return;

    final providerLabel = service.provider == SyncProvider.dropbox
        ? 'Dropbox'
        : 'Google Drive';

    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'sync_wipe_cloud'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.warning_amber_rounded,
        description: 'sync_confirm_wipe'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'sync_wipe_cloud'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );

    if (confirmed != true) return;

    if (!mounted) return;
    await GlazeBottomSheet.show<void>(
      context,
      title: 'sync_wipe_cloud'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_forever_rounded,
        description: 'sync_confirm_wipe_final'.tr(),
      ),
      input: BottomSheetInput(
        placeholder: providerLabel,
        confirmLabel: 'btn_ok'.tr(),
        onConfirm: (typed) async {
          if (typed.trim().toLowerCase() != providerLabel.toLowerCase()) {
            if (context.mounted) {
              GlazeErrorDialog.show(
                context,
                "${'title_error'.tr()}: ${'sync_invalid_phrase'.tr()}",
              );
            }
            return;
          }

          setState(() {});
          try {
            await _ctrl.wipeCloudData(
              onProgress: (p) {
                if (mounted) ref.read(syncProgressProvider.notifier).state = p;
              },
              providerLabel: providerLabel,
            );
            if (mounted) {
              setState(() {});
              GlazeToast.show(context, 'sync_wipe_done'.tr());
            }
          } catch (e) {
            if (mounted) {
              setState(() {});
              GlazeErrorDialog.show(
                context,
                e,
                prefix: "${'title_error'.tr()}: ",
              );
            }
          }
        },
      ),
    );
  }

  Future<void> _doSync(String mode) async {
    setState(() {});
    final result = await _ctrl.doSync(mode);
    if (mounted) {
      setState(() {});
      if (result != null) {
        if (result.startsWith('Sync failed')) {
          GlazeErrorDialog.show(context, result);
        } else {
          GlazeToast.show(context, result);
        }
      }
    }
  }

  Future<void> _resolveConflict(SyncConflict conflict, String choice) async {
    final result = await _ctrl.resolveConflict(conflict, choice);
    if (mounted && result != null) {
      if (result.startsWith('Could not')) {
        GlazeErrorDialog.show(context, result);
      } else {
        GlazeToast.show(context, result);
      }
    }
  }

  Future<void> _resolveAllConflicts(String choice) async {
    final result = await _ctrl.resolveAllConflicts(choice);
    if (mounted && result != null) {
      if (result.startsWith('Could not')) {
        GlazeErrorDialog.show(context, result);
      } else {
        GlazeToast.show(context, result);
      }
    }
  }

  void _setAutoSync(bool val) async {
    await _ctrl.setAutoSync(val);
  }

  void _updateAutoSyncThreshold(int count) async {
    await _ctrl.updateAutoSyncThreshold(count);
    if (mounted) setState(() {});
  }

  void _setIncludeApiKeys(bool val) async {
    await _ctrl.setIncludeApiKeys(val);
    if (mounted) setState(() {});
  }
}
