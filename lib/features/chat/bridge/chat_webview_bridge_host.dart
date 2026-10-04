import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/transport/chat_transport_request.dart';
import '../../../core/llm/transport/llm_protocol.dart';
import '../../../core/llm/transport/transport_factory.dart';
import '../../../core/state/db_provider.dart';
import '../../extensions/models/connection_profiles.dart';
import '../../extensions/models/preset_permissions.dart';
import '../../extensions/models/trigger_mode.dart';
import '../../extensions/models/trigger_result.dart';
import '../../extensions/providers/extension_presets_provider.dart';
import '../../extensions/providers/extensions_settings_provider.dart';
import '../../extensions/providers/global_variables_repo_provider.dart';
import '../../extensions/providers/preset_permissions_provider.dart';
import '../../extensions/services/audio_bridge_service.dart';
import '../../extensions/services/command_registry.dart';
import '../../extensions/services/connection_profile_resolver.dart';
import '../../extensions/services/generation_dispatcher.dart';
import '../../extensions/services/js_bridge_service.dart';
import '../../extensions/services/js_bridge_toast_controller.dart';
import '../../extensions/services/runtime_prompt_injection_service.dart';
import '../../extensions/services/trigger_generation_handler.dart';
import '../../extensions/state/message_variables_notifier.dart';
import '../../settings/api_list_provider.dart';

/// Owns the chat WebView's bridge-side dependencies: the [JsBridgeService]
/// handler implementations (generateText / injectPrompt / uninjectPrompt /
/// triggerGeneration / playAudio / showToast / executeCommand), the
/// permission gate, and the long-lived helper instances
/// (audio bridge, toast controller, command registry, trigger handler,
/// prompt injection notifier).
///
/// Extracted from [ChatWebViewWidget] so the widget only has to call
/// [buildJsBridgeService] in `onWebViewCreated` and [dispose] on teardown.
/// All Riverpod reads still happen through the [WidgetRef] provided at
/// construction time, so the host follows the widget's lifecycle
/// (ref → widget) one-to-one.
class ChatWebViewBridgeHost {
  ChatWebViewBridgeHost({
    required this.ref,
    required this.overlayContextResolver,
    required this.currentSessionId,
    required this.currentCharacterId,
    required this.isActive,
  });

  final WidgetRef ref;
  final BuildContext? Function() overlayContextResolver;
  final String? Function() currentSessionId;
  final String? Function() currentCharacterId;
  final bool Function() isActive;
  bool _disposed = false;

  bool get active => !_disposed && isActive();

  void _ensureActive() {
    if (!active) throw StateError('ChatWebViewBridgeHost is inactive');
  }

  String? _activeSessionId() {
    _ensureActive();
    return currentSessionId();
  }

  String? _activeCharacterId() {
    _ensureActive();
    return currentCharacterId();
  }

  static const ConnectionProfileResolver _profileResolver =
      ConnectionProfileResolver();

  final AudioBridgeService _audioBridge = AudioBridgeService();

  final JsBridgeToastController _toastController = JsBridgeToastController();

  /// Resolves the preset permissions for the current preset, returning
  /// `false` (default-deny) if the lookup fails. Mirrors the previous
  /// in-widget `_bridgePermissionCheck`.
  bool _bridgePermissionCheck(String capabilityId) {
    if (!active) return false;
    try {
      final permissions = ref.read(activePresetPermissionsProvider);
      return permissions.isGrantedById(capabilityId);
    } catch (_) {
      return false;
    }
  }

  /// Build a fresh [JsBridgeService] wired to the current widget state.
  /// Called from `onWebViewCreated`; its command registry re-enters this same
  /// bridge so dedicated capabilities and context resolution remain canonical.
  Future<JsBridgeService?> buildJsBridgeService() async {
    if (!active) return null;
    final globalRepo = await ref.read(globalVariablesRepoProvider.future);
    if (!active) return null;
    late final JsBridgeService bridge;
    final commandRegistry = buildWiredCommandRegistry(
      WiredCommandDeps(bridgeDispatch: (request) => bridge.dispatch(request)),
    );
    bridge = JsBridgeService(
      chatRepo: ref.read(chatRepoProvider),
      characterRepo: ref.read(characterRepoProvider),
      globalVariablesRepo: globalRepo,
      messageVariables: () {
        _ensureActive();
        return ref.read(messageVariablesProvider.notifier);
      },
      currentSessionId: _activeSessionId,
      currentCharacterId: _activeCharacterId,
      generateText: _generateBridgeText,
      injectPrompt: _injectBridgePrompt,
      uninjectPrompt: _uninjectBridgePrompt,
      triggerGeneration: _triggerBridgeGeneration,
      permissionCheck: _bridgePermissionCheck,
      playAudio: _playBridgeAudio,
      executeCommand: (command, args, context) =>
          _executeBridgeCommand(commandRegistry, command, args, context),
      showToast: _showBridgeToast,
    );
    if (!active) return null;
    return bridge;
  }

  Future<String> _generateBridgeText(
    String prompt,
    Map<String, dynamic> options,
    Map<String, dynamic> bridgeContext,
  ) async {
    _ensureActive();
    await ref.read(apiListProvider.future);
    _ensureActive();
    final configs = ref.read(apiListProvider).value ?? const [];
    final activeApiConfig = ref.read(activeApiConfigProvider);
    final profile =
        ConnectionProfileX.parse(options['preset']) ?? ConnectionProfile.medium;
    final activePresetId = ref.read(extensionsSettingsProvider).activePresetId;
    final preset = activePresetId == null
        ? null
        : ref
              .read(extensionPresetsProvider)
              .where((p) => p.id == activePresetId)
              .firstOrNull;
    final apiConfig = _profileResolver.resolve(
      preset,
      profile,
      activeApiConfig,
      configs,
    );
    if (apiConfig == null) {
      throw StateError('No active API config available');
    }
    final endpointRequired = apiConfig.protocol != LlmProtocol.openrouter;
    if ((endpointRequired && apiConfig.endpoint.isEmpty) ||
        apiConfig.model.isEmpty) {
      throw StateError('Active API config is incomplete');
    }

    final cancelToken = CancelToken();
    final completer = Completer<String>();
    final transport = pickChatTransport(apiConfig.protocol);
    unawaited(
      transport.stream(
        request: ChatTransportRequest.fromApiConfig(
          apiConfig,
          messages: [
            {'role': 'user', 'content': prompt},
          ],
          stream: false,
          sessionId: _activeSessionId(),
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
    return completer.future.timeout(
      const Duration(seconds: 55),
      onTimeout: () {
        cancelToken.cancel('glaze.generateText timed out');
        throw TimeoutException('glaze.generateText timed out');
      },
    );
  }

  Map<String, dynamic> _injectBridgePrompt(
    String id,
    String content,
    Map<String, dynamic> options,
    Map<String, dynamic> bridgeContext,
  ) {
    _ensureActive();
    final sessionId =
        (bridgeContext['sessionId'] as String?) ?? _activeSessionId();
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('Chat session context is not available');
    }
    final rawDepth = options['depth'];
    final depth = rawDepth == null
        ? 0
        : rawDepth is int
        ? rawDepth
        : throw ArgumentError('injectPrompt depth must be an integer');
    final rawRole = options['role'];
    if (rawRole != null && rawRole is! String) {
      throw ArgumentError('injectPrompt role must be a string');
    }
    final role = rawRole as String? ?? 'system';
    final injected = ref
        .read(runtimePromptInjectionProvider.notifier)
        .inject(
          sessionId: sessionId,
          id: id,
          content: content,
          depth: depth,
          role: role,
        );
    return {'id': injected.id, 'depth': injected.depth, 'role': injected.role};
  }

  Map<String, dynamic> _uninjectBridgePrompt(
    String id,
    Map<String, dynamic> bridgeContext,
  ) {
    _ensureActive();
    final sessionId =
        (bridgeContext['sessionId'] as String?) ?? _activeSessionId();
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('Chat session context is not available');
    }
    final removed = ref
        .read(runtimePromptInjectionProvider.notifier)
        .uninject(sessionId: sessionId, id: id);
    return {'id': id.trim(), 'removed': removed};
  }

  Future<Map<String, dynamic>> _triggerBridgeGeneration(
    String? charId,
    Map<String, dynamic> params,
  ) async {
    if (!active) return TriggerNoSession(mode: TriggerMode.auto).toMap();
    final resolvedCharId =
        (params['characterId'] as String?) ?? (charId) ?? _activeCharacterId();
    if (resolvedCharId == null || resolvedCharId.isEmpty) {
      return TriggerNoSession(mode: TriggerMode.auto).toMap();
    }
    final dispatcher = ref.read(generationDispatcherProvider);
    final handler = TriggerGenerationHandler(
      dispatcher: dispatcher,
      log: (line) => debugPrint(line),
    );
    final result = await handler.handle(charId: resolvedCharId, params: params);
    _ensureActive();
    return result;
  }

  Future<void> _playBridgeAudio(String? source, Map<String, dynamic> options) {
    if (!active) return Future.value();
    return _audioBridge.play(source, options);
  }

  void _showBridgeToast(String? message, Map<String, dynamic> options) {
    if (!active) return;
    final severity = GlazeToastSeverity.parse(options['severity'] as String?);
    // Re-resolve the BuildContext on every call so the toast surfaces
    // from the currently mounted screen, not the snapshot at bridge init.
    _toastController.overlayResolver = overlayContextResolver;
    _toastController.show(
      message,
      severity: severity,
      actionLabel: options['action'] as String?,
    );
  }

  Future<Map<String, dynamic>> _executeBridgeCommand(
    CommandRegistry commandRegistry,
    String command,
    Map<String, dynamic> args,
    Map<String, dynamic> context,
  ) async {
    _ensureActive();
    final characterId =
        (context['characterId'] as String?) ?? _activeCharacterId();
    final result = await commandRegistry.run(
      command,
      args,
      context: CommandContext(
        charId: characterId,
        presetId: ref.read(extensionsSettingsProvider).activePresetId,
        bridgeContext: {
          ...context,
          if (!context.containsKey('sessionId'))
            'sessionId': _activeSessionId(),
          if (!context.containsKey('characterId')) 'characterId': characterId,
        },
      ),
    );
    _ensureActive();
    return result.toMap();
  }

  /// Release long-lived resources owned by this host. Called from the
  /// widget's [State.dispose]. Mirrors the previous in-widget disposal
  /// path: drop the audio player.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _audioBridge.dispose();
  }
}
