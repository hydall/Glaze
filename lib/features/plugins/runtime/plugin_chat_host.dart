import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path/path.dart' as p;

import '../../../core/plugins/plugin_hooks.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../chat/bridge/chat_bridge_controller.dart';
import '../../chat/bridge/chat_bridge_registry.dart';
import '../../chat/chat_provider.dart';
import '../../chat/chat_state.dart';
import '../models/installed_plugin.dart';
import '../providers/plugin_library_provider.dart';
import 'plugin_chat_runtime.dart';
import 'plugin_message_diff.dart';
import 'plugin_runtime_payload.dart';
import 'riverpod_tavo_host.dart';
import 'tavo_bridge_service.dart';
import 'tavo_data_api.dart';
import 'tavo_host.dart';
import 'tavo_variable_store.dart';

/// The running plugin runtime of a chat, by character id; null while the
/// chat has no WebView bridge or no enabled plugins.
final pluginRuntimeRegistryProvider =
    StateProvider.family<PluginChatRuntime?, String>((ref, charId) => null);

/// Starts the enabled plugins inside the chat WebView of [charId] once its
/// bridge is published, and keeps them fed with chat/message events.
class PluginChatHost extends ConsumerStatefulWidget {
  const PluginChatHost({super.key, required this.charId, required this.child});

  final String charId;
  final Widget child;

  @override
  ConsumerState<PluginChatHost> createState() => _PluginChatHostState();
}

class _PluginChatHostState extends ConsumerState<PluginChatHost> {
  PluginChatRuntime? _runtime;
  TavoHost? _host;
  int _epoch = 0;
  String? _sessionId;
  Map<String, PluginMessageSignature> _snapshot = const {};
  String? _locale;
  late final PluginHookRegistry _hooks;
  late final StateController<PluginChatRuntime?> _registry;

  @override
  void initState() {
    super.initState();
    // Captured up front: `ref` must not be used once the widget unmounts.
    _hooks = ref.read(pluginHookRegistryProvider);
    _registry = ref.read(pluginRuntimeRegistryProvider(widget.charId).notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_restart());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final locale = context.locale.toLanguageTag();
    if (_locale != null && _locale != locale) {
      _locale = locale;
      unawaited(_pushLocalization());
    }
    _locale = locale;
  }

  @override
  void dispose() {
    _epoch++;
    _detach();
    super.dispose();
  }

  void _detach() {
    final runtime = _runtime;
    _runtime = null;
    _host = null;
    if (runtime == null) return;
    _hooks.unregister(widget.charId, runtime);
    final registry = _registry;
    // Deferred: providers may not be modified while the tree is unmounting.
    Future(() {
      if (identical(registry.state, runtime)) registry.state = null;
    });
    runtime.dispose();
  }

  /// Rebuilds every plugin frame from scratch: bridge change, plugin list
  /// change, settings change.
  Future<void> _restart() async {
    final epoch = ++_epoch;
    _detach();
    final bridge = ref.read(chatBridgeRegistryProvider(widget.charId));
    final plugins = ref.read(enabledPluginsProvider);
    if (bridge == null || plugins.isEmpty) return;
    try {
      await _attach(bridge, plugins, epoch);
    } catch (e) {
      debugPrint('[PluginChatHost] start failed: $e');
    }
  }

  Future<void> _attach(
    ChatBridgeController bridge,
    List<InstalledPlugin> plugins,
    int epoch,
  ) async {
    final store = await ref.read(pluginStoreProvider.future);
    final sdk = await rootBundle.loadString(
      'assets/chat_webview/plugins/tavo_sdk.js',
    );
    if (!mounted || epoch != _epoch) return;
    final variables = TavoVariableStore(
      chatRepo: ref.read(chatRepoProvider),
      globalFile: File(p.join(store.dataRoot, '_global_variables.json')),
    );
    late final PluginChatRuntime runtime;
    final host = RiverpodTavoHost(
      ref: ref,
      charId: widget.charId,
      store: store,
      variables: variables,
      contextResolver: () => mounted ? context : null,
      onVariablesChanged: (scope, root) => runtime.pushVars(scope, root),
    );
    final byId = {for (final x in plugins) x.id: x};
    runtime = PluginChatRuntime(
      bridge: bridge,
      service: TavoBridgeService(host: host, pluginById: (id) => byId[id]),
      chatId: () => host.sessionId,
      onCancelledSend: (message) {
        if (mounted && message != null && message.trim().isNotEmpty) {
          GlazeToast.show(context, message, isWarning: true);
        }
      },
    );

    final sessionId = host.sessionId;
    final chatVars = sessionId == null
        ? <String, dynamic>{}
        : await variables.read('chat', sessionId);
    final globalVars = await variables.read('global', null);
    final payload = await PluginRuntimePayloadBuilder(store: store).build(
      plugins: plugins,
      locale: _locale ?? 'en',
      sdkSource: sdk,
      chatVars: chatVars,
      globalVars: globalVars,
    );
    if (!mounted || epoch != _epoch) {
      runtime.dispose();
      return;
    }
    _runtime = runtime;
    _host = host;
    await runtime.setup(payload);
    if (!mounted || epoch != _epoch) return;
    _hooks.register(widget.charId, runtime);
    _registry.state = runtime;
    final session = host.currentSession();
    _sessionId = session?.id;
    _snapshot = pluginMessageSignatures(session?.messages ?? const []);
    if (session != null) {
      runtime.dispatchEvent('chat:opened', {
        'chatId': session.id,
        'chat': tavoCurrentChatJson(host),
      });
    }
  }

  Future<void> _pushLocalization() async {
    final runtime = _runtime;
    if (runtime == null) return;
    final locale = _locale ?? 'en';
    await runtime.updateLocalization([
      for (final plugin in ref.read(enabledPluginsProvider))
        if (plugin.manifest.specVersion >= 2)
          {
            'pluginId': plugin.id,
            'i18n': plugin.localizer(locale).runtimeSnapshot(),
          },
    ]);
  }

  void _onChatState(ChatState? state) {
    final runtime = _runtime;
    final host = _host;
    if (runtime == null || host == null || state == null) return;
    final session = state.session;
    if (session?.id != _sessionId) {
      final previous = _sessionId;
      _sessionId = session?.id;
      _snapshot = pluginMessageSignatures(session?.messages ?? const []);
      if (previous != null) {
        runtime.dispatchEvent('chat:closed', {'chatId': previous});
      }
      if (session != null) {
        unawaited(_announceSession(runtime, host, session.id));
      }
      return;
    }
    if (session == null || state.isGenerating || state.isSendPending) return;
    final changes = diffPluginMessages(_snapshot, session.messages);
    if (changes.isEmpty) return;
    _snapshot = pluginMessageSignatures(session.messages);
    for (final change in changes) {
      runtime.dispatchEvent('message:${change.change}', {
        'chatId': session.id,
        'change': change.change,
        'message': change.message == null
            ? {'id': change.id}
            : tavoMessageJson(
                change.message!,
                index: change.index,
                charId: widget.charId,
              ),
      });
    }
  }

  Future<void> _announceSession(
    PluginChatRuntime runtime,
    TavoHost host,
    String sessionId,
  ) async {
    try {
      runtime.pushVars('chat', await host.variables.read('chat', sessionId));
    } catch (_) {
      // A session that vanished mid-switch has no variables to push.
    }
    if (!identical(_runtime, runtime) || _sessionId != sessionId) return;
    runtime.dispatchEvent('chat:opened', {
      'chatId': sessionId,
      'chat': tavoCurrentChatJson(host),
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatBridgeRegistryProvider(widget.charId), (prev, next) {
      if (!identical(prev, next)) unawaited(_restart());
    });
    ref.listen(enabledPluginsProvider, (_, _) => unawaited(_restart()));
    ref.listen(
      chatProvider(widget.charId),
      (_, next) => _onChatState(next.value),
    );
    return widget.child;
  }
}
