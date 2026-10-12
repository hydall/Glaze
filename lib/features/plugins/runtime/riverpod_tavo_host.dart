import 'dart:async';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/llm/transport/chat_transport_request.dart';
import '../../../core/llm/transport/transport_factory.dart';
import '../../../core/models/character.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/persona.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/persona_resolution.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../chat/chat_provider.dart';
import '../../chat/composer_text_bridge.dart';
import '../../personas/persona_list_provider.dart';
import '../../settings/api_list_provider.dart';
import '../services/plugin_store.dart';
import 'tavo_file_store.dart';
import 'tavo_host.dart';
import 'tavo_variable_store.dart';

/// [TavoHost] backed by the app's providers, for the chat [charId].
class RiverpodTavoHost implements TavoHost {
  RiverpodTavoHost({
    required this.ref,
    required this.charId,
    required this.store,
    required this.variables,
    required this.contextResolver,
    required this.onVariablesChanged,
  });

  final WidgetRef ref;
  @override
  final String charId;
  final PluginStore store;
  @override
  final TavoVariableStore variables;
  final BuildContext? Function() contextResolver;
  final void Function(String scope, Map<String, dynamic> root)
  onVariablesChanged;

  final Map<String, TavoFileStore> _files = {};

  @override
  String? get sessionId => currentSession()?.id;

  @override
  ChatSession? currentSession() =>
      ref.read(chatProvider(charId)).value?.session;

  @override
  Character? currentCharacter() => ref.read(characterByIdProvider(charId));

  @override
  Future<List<Character>> characters() async =>
      await ref.read(charactersProvider.future);

  @override
  Persona? currentPersona() => ref.read(
    effectivePersonaForChatProvider((charId: charId, sessionId: sessionId)),
  );

  @override
  Future<List<Persona>> personas() async =>
      await ref.read(personaListProvider.future);

  @override
  ComposerTextAccess? composer() => ref.read(composerTextBridgeProvider).access;

  BuildContext _context() {
    final context = contextResolver();
    if (context == null || !context.mounted) {
      throw StateError('The chat is not visible');
    }
    return context;
  }

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
    List<TavoOption> options, {
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
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop(o.value),
          ),
      ],
    );
  }

  @override
  Future<Map<String, Object?>> ask({
    required String question,
    required List<TavoOption> options,
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
                  onTap: () => Navigator.of(
                    context,
                    rootNavigator: true,
                  ).pop({'answer': o.value, 'source': 'option'}),
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
                Navigator.of(
                  context,
                  rootNavigator: true,
                ).pop({'answer': trimmed, 'source': 'custom'});
              },
            )
          : null,
    );
    if (answer == null) return {'status': 'cancelled'};
    return {'status': 'answered', ...answer};
  }

  @override
  Future<String> generate(String prompt, Map<String, dynamic> options) async {
    await ref.read(apiListProvider.future);
    final apiConfig = ref.read(activeApiConfigProvider);
    if (apiConfig == null || apiConfig.model.isEmpty) {
      throw StateError('No API connection is configured');
    }
    final messages = <Map<String, dynamic>>[];
    if (options['context'] == true) {
      final history = currentSession()?.messages ?? const <ChatMessage>[];
      for (final m
          in history
              .where((m) => !m.isHidden)
              .toList()
              .reversed
              .take(40)
              .toList()
              .reversed) {
        if (m.role != 'user' && m.role != 'assistant') continue;
        messages.add({'role': m.role, 'content': m.content});
      }
    }
    messages.add({'role': 'user', 'content': prompt});

    final cancelToken = CancelToken();
    final completer = Completer<String>();
    unawaited(
      pickChatTransport(apiConfig.protocol).stream(
        request: ChatTransportRequest.fromApiConfig(
          apiConfig,
          messages: messages,
          stream: false,
          sessionId: sessionId,
        ),
        cancelToken: cancelToken,
        onComplete: (text, _, {rawResponseJson}) {
          if (!completer.isCompleted) completer.complete(text);
        },
        onError: (error) {
          if (!completer.isCompleted) completer.completeError(error);
        },
      ),
    );
    final timeoutMs = options['timeout'];
    final limit = timeoutMs is num && timeoutMs > 0
        ? Duration(milliseconds: timeoutMs.toInt())
        : const Duration(minutes: 5);
    return completer.future.timeout(
      limit,
      onTimeout: () {
        cancelToken.cancel('tavo.generate timed out');
        throw TimeoutException('tavo.generate timed out');
      },
    );
  }

  @override
  TavoFileStore files(String pluginId) => _files.putIfAbsent(
    pluginId,
    () => TavoFileStore(dataDir: store.dataDir(pluginId)),
  );

  @override
  void variablesChanged(String scope, Map<String, dynamic> root) =>
      onVariablesChanged(scope, root);
}
