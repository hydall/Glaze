import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/file_export_service.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/image_viewer.dart';
import '../../chat/chat_provider.dart';
import '../../chat/composer_text_bridge.dart';
import '../models/plugin_manifest.dart';
import '../providers/plugin_history_provider.dart';
import '../providers/plugin_network_log_provider.dart';
import '../services/plugin_store.dart';
import 'plugin_api.dart';
import 'plugin_file_store.dart';
import 'plugin_variable_store.dart';

/// [PluginApiHost] and [PluginUi] for the chat [charId], backed by the app's
/// providers and the chat screen's context.
class ChatPluginApiHost implements PluginApiHost, PluginUi {
  ChatPluginApiHost({
    required this.ref,
    required this.charId,
    required this.store,
    required this.variables,
    required this.contextResolver,
    required this.onVariablesChanged,
  });

  @override
  final Ref ref;
  @override
  final String charId;
  final PluginStore store;
  @override
  final PluginVariableStore variables;
  final BuildContext? Function() contextResolver;
  final void Function(String pluginId, String scope, Map<String, dynamic> root)
  onVariablesChanged;

  final Map<String, PluginFileStore> _files = {};

  @override
  PluginUi get ui => this;

  @override
  String? get sessionId => ref.read(chatProvider(charId)).value?.session?.id;

  @override
  ComposerTextAccess? composer() => ref.read(composerTextBridgeProvider).access;

  @override
  PluginFileStore files(String pluginId) => _files.putIfAbsent(
    pluginId,
    () => PluginFileStore(dataDir: store.dataDir(pluginId)),
  );

  @override
  void variablesChanged(
    String pluginId,
    String scope,
    Map<String, dynamic> root,
  ) => onVariablesChanged(pluginId, scope, root);

  @override
  void networkUsed(String pluginId, String host, {required bool blocked}) =>
      unawaited(
        ref
            .read(pluginNetworkLogProvider(pluginId).notifier)
            .record(host, blocked: blocked),
      );

  BuildContext _context() {
    final context = contextResolver();
    if (context == null || !context.mounted) {
      throw const PluginApiError('unavailable', 'The chat is not visible');
    }
    return context;
  }

  void _pop<T>(BuildContext context, [T? value]) =>
      Navigator.of(context, rootNavigator: true).pop(value);

  @override
  void toast(String pluginName, String text) {
    final context = contextResolver();
    if (context != null && context.mounted) {
      GlazeToast.show(context, text, source: pluginName);
    }
  }

  /// Signs a sheet a plugin opened, so its question is not taken for the
  /// app's.
  String _requestFrom(String pluginName) =>
      'plugins_request_from'.tr(namedArgs: {'name': pluginName});

  @override
  Future<void> openUrl(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Future<String?> select(
    String pluginName,
    List<PluginOption> options, {
    String? title,
    String? defaultValue,
  }) {
    final context = _context();
    return GlazeBottomSheet.show<String>(
      context,
      title: title,
      source: _requestFrom(pluginName),
      items: [
        for (final o in options)
          BottomSheetItem(
            label: o.label,
            hint: o.description,
            icon: o.value == defaultValue ? Icons.check : null,
            onTap: () => _pop(context, o.value),
          ),
      ],
    );
  }

  @override
  Future<Map<String, Object?>> ask({
    required String pluginName,
    required String question,
    required List<PluginOption> options,
    required bool allowOther,
    String? placeholder,
    String? defaultValue,
  }) async {
    final context = _context();
    final answer = await GlazeBottomSheet.show<Map<String, Object?>>(
      context,
      title: question,
      source: _requestFrom(pluginName),
      items: options.isEmpty
          ? null
          : [
              for (final o in options)
                BottomSheetItem(
                  label: o.label,
                  hint: o.description,
                  icon: o.value == defaultValue ? Icons.check : null,
                  onTap: () =>
                      _pop(context, {'answer': o.value, 'source': 'option'}),
                ),
            ],
      input: allowOther
          ? BottomSheetInput(
              placeholder: placeholder ?? '',
              value: options.any((o) => o.value == defaultValue)
                  ? ''
                  : defaultValue ?? '',
              confirmLabel: 'plugins_ask_submit'.tr(),
              onConfirm: (text) {
                final trimmed = text.trim();
                if (trimmed.isEmpty) return;
                _pop(context, {'answer': trimmed, 'source': 'custom'});
              },
            )
          : null,
    );
    if (answer == null) return {'status': 'cancelled'};
    return {'status': 'answered', ...answer};
  }

  /// Refused actions the user was already told about, by plugin.
  static final Set<String> _deniedToasts = {};

  @override
  void allowed(String pluginId, String actionKey, String permission) =>
      unawaited(
        ref
            .read(pluginHistoryProvider(pluginId).notifier)
            .allowed(actionKey, permission),
      );

  @override
  void denied(
    String pluginId,
    String pluginName,
    String actionKey, {
    required String permission,
    bool shown = true,
  }) {
    unawaited(
      ref
          .read(pluginHistoryProvider(pluginId).notifier)
          .denied(actionKey, permission),
    );
    if (!shown) return;
    // Once per action until the app restarts: a plugin retrying, or
    // subscribing again in every chat, is only counted in its history.
    if (!_deniedToasts.add('$pluginId|$actionKey')) return;
    final context = contextResolver();
    if (context == null || !context.mounted) return;
    final action = actionKey.tr();
    GlazeToast.show(
      context,
      'plugins_denied_toast'.tr(
        namedArgs: {'name': pluginName, 'action': action},
      ),
      isWarning: true,
    );
  }

  @override
  Future<PluginConsentAnswer?> consent({
    required String pluginName,
    required String permission,
    required String summary,
  }) async {
    final context = contextResolver();
    if (context == null || !context.mounted) return null;
    return GlazeBottomSheet.show<PluginConsentAnswer>(
      context,
      title: 'plugins_consent_title'.tr(namedArgs: {'name': pluginName}),
      bigInfo: BottomSheetBigInfo(
        icon: permission == PluginPermission.images
            ? Icons.image_outlined
            : Icons.edit_note_rounded,
        description: summary,
      ),
      items: [
        BottomSheetItem(
          label: 'plugins_consent_once'.tr(),
          icon: Icons.check_rounded,
          onTap: () => _pop(context, PluginConsentAnswer.once),
        ),
        BottomSheetItem(
          label: 'plugins_consent_always'.tr(),
          icon: Icons.done_all_rounded,
          onTap: () => _pop(context, PluginConsentAnswer.always),
        ),
        BottomSheetItem(
          label: 'plugins_consent_deny'.tr(),
          icon: Icons.block_rounded,
          isDestructive: true,
          onTap: () => _pop(context, PluginConsentAnswer.deny),
        ),
      ],
    );
  }

  @override
  Future<void> previewImage(Uint8List bytes) async {
    ImageViewer.show(_context(), imageProvider: MemoryImage(bytes));
  }

  @override
  Future<void> share(Uint8List bytes, String filename) async {
    await FileExportService.exportBytes(
      bytes: bytes,
      filename: filename,
      subfolder: 'plugins',
    );
  }

  @override
  Future<List<PickedPluginFile>> pickFiles({
    required bool multiple,
    List<String>? extensions,
  }) async {
    final custom =
        extensions != null && extensions.isNotEmpty && !Platform.isIOS;
    final result = await FilePicker.pickFiles(
      allowMultiple: multiple,
      type: custom ? FileType.custom : FileType.any,
      allowedExtensions: custom ? extensions : null,
      withData: true,
    );
    if (result == null) return const [];
    return [
      for (final f in result.files)
        (name: f.name, bytes: f.bytes ?? await File(f.path!).readAsBytes()),
    ];
  }

  @override
  Future<void> openChat(String characterId, int sessionIndex) async {
    _context().go('/chat/$characterId?session=$sessionIndex');
  }
}
