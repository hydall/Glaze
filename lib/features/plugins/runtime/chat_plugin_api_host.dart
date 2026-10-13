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
  final void Function(String scope, Map<String, dynamic> root)
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
  void variablesChanged(String scope, Map<String, dynamic> root) =>
      onVariablesChanged(scope, root);

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
  void toast(String text) {
    final context = contextResolver();
    if (context != null && context.mounted) GlazeToast.show(context, text);
  }

  @override
  Future<void> openUrl(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Future<String?> select(
    List<PluginOption> options, {
    String? title,
    String? defaultValue,
  }) {
    final context = _context();
    return GlazeBottomSheet.show<String>(
      context,
      title: title,
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

  @override
  Future<PluginConsentAnswer> consent({
    required String pluginName,
    required PluginConsent kind,
    required String summary,
  }) async {
    final context = contextResolver();
    if (context == null || !context.mounted) return PluginConsentAnswer.deny;
    final answer = await GlazeBottomSheet.show<PluginConsentAnswer>(
      context,
      title: 'plugins_consent_title'.tr(namedArgs: {'name': pluginName}),
      bigInfo: BottomSheetBigInfo(
        icon: kind == PluginConsent.images
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
    return answer ?? PluginConsentAnswer.deny;
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
