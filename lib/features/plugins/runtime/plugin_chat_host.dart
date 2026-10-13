import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/plugins/plugin_hooks.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../chat/bridge/chat_bridge_controller.dart';
import '../../chat/bridge/chat_bridge_registry.dart';
import '../../chat/chat_provider.dart';
import '../../chat/chat_state.dart';
import '../compat/tavo/tavo_manifest_converter.dart';
import '../models/installed_plugin.dart';
import '../models/plugin_manifest.dart';
import '../providers/plugin_library_provider.dart';
import '../providers/plugin_network_log_provider.dart';
import 'api/chats_api.dart';
import 'api/files_api.dart';
import 'api/shapes.dart';
import 'chat_plugin_api_host.dart';
import 'plugin_bridge_service.dart';
import 'plugin_chat_runtime.dart';
import 'plugin_message_diff.dart';
import 'plugin_runtime_payload.dart';

/// The running plugin runtime of a chat, by character id; null while the
/// chat has no WebView bridge or no enabled plugins.
final pluginRuntimeRegistryProvider =
    StateProvider.family<PluginChatRuntime?, String>((ref, charId) => null);

const _sdkAsset = 'assets/chat_webview/plugins/plugin_sdk.js';
const _compatAssets = {
  kTavoCompat: 'assets/chat_webview/plugins/compat/tavo_compat.js',
};

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
  ChatPluginApiHost? _host;
  int _epoch = 0;
  String? _sessionId;
  Map<String, PluginMessageSignature> _snapshot = const {};
  String? _messagesKey;
  String? _locale;

  /// What `chat:updated` compares: the open chat's settings as last sent.
  String? _chatSignature;
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
    runtime.bridge.onPluginActionFailed = null;
    runtime.bridge.onPluginNetwork = null;
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

  String _name(InstalledPlugin plugin) =>
      plugin.localizer(_locale ?? 'en').resolve(plugin.manifest.name);

  Future<void> _attach(
    ChatBridgeController bridge,
    List<InstalledPlugin> plugins,
    int epoch,
  ) async {
    final store = await ref.read(pluginStoreProvider.future);
    final sdk = await rootBundle.loadString(_sdkAsset);
    final compat = {
      for (final e in _compatAssets.entries)
        e.key: await rootBundle.loadString(e.value),
    };
    final variables = await ref.read(pluginVariableStoreProvider.future);
    if (!mounted || epoch != _epoch) return;
    late final PluginChatRuntime runtime;
    final host = ChatPluginApiHost(
      ref: ref.read(pluginRefProvider),
      charId: widget.charId,
      store: store,
      variables: variables,
      contextResolver: () => mounted ? context : null,
      onVariablesChanged: (id, scope, root) =>
          runtime.pushVars(id, scope, root),
    );
    final library = ref.read(pluginLibraryProvider.notifier);
    final builder = PluginRuntimePayloadBuilder(store: store);
    final fileHandlers = [
      for (final plugin in [...plugins]..sort((a, b) => a.id.compareTo(b.id)))
        // Attached files are staged in the plugin's files.
        if (plugin.allows(PluginPermission.files))
          for (final handler in plugin.manifest.fileHandlers)
            PluginFileHandlerEntry(
              pluginId: plugin.id,
              handler: handler,
              scripts: () => builder.fileHandlerScripts(plugin, handler),
            ),
    ];
    runtime = PluginChatRuntime(
      bridge: bridge,
      service: PluginBridgeService(
        host: host,
        // Read live: "always allow" answers land in the library without
        // restarting the frames.
        pluginById: (id) => ref
            .read(enabledPluginsProvider)
            .where((x) => x.id == id)
            .firstOrNull,
        pluginName: _name,
        text: (key) => key.tr(),
        onAlwaysAllow: library.allowAlways,
        onDeny: (id, permission) =>
            library.setPermission(id, permission, false),
      ),
      chatId: () => host.sessionId,
      fileHandlers: fileHandlers,
      stageFile: (pluginId, name, bytes) async {
        final target = host
            .files(pluginId)
            .resolve(safeFileName(name, 'file'), scope: 'tmp', sessionId: null);
        await target.file.parent.create(recursive: true);
        await target.file.writeAsBytes(bytes, flush: true);
        return {
          'path': target.virtualPath,
          'name': name,
          'mimeType': pluginMimeType(name),
          'size': bytes.length,
        };
      },
      onCancelledSend: (message) {
        if (mounted && message != null && message.trim().isNotEmpty) {
          GlazeToast.show(context, message, isWarning: true);
        }
      },
    );
    bridge.onPluginNetwork = (report) {
      final id = report['pluginId'];
      final host = report['host'];
      if (id is! String || host is! String || host.isEmpty) return;
      if (!plugins.any((x) => x.id == id)) return;
      unawaited(
        ref
            .read(pluginNetworkLogProvider(id).notifier)
            .record(host, blocked: report['blocked'] == true),
      );
    };
    bridge.onPluginActionFailed = (failure) {
      if (!mounted) return;
      GlazeToast.show(
        context,
        failure['reason'] == 'missing-handler'
            ? 'plugins_action_missing'.tr()
            : 'plugins_action_failed'.tr(
                namedArgs: {
                  'error': '${failure['message'] ?? failure['reason'] ?? '?'}',
                },
              ),
        isError: true,
      );
    };

    final sessionId = host.sessionId;
    final payload = await builder.build(
      plugins: plugins,
      locale: _locale ?? 'en',
      sdkSource: sdk,
      compatSources: compat,
      readVars: (plugin, scope) async => scope == 'chat' && sessionId == null
          ? <String, dynamic>{}
          : variables.read(plugin.id, scope, sessionId),
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
    final state = ref.read(chatProvider(widget.charId)).value;
    final session = state?.session;
    _sessionId = session?.id;
    _snapshot = pluginMessageSignatures(session?.messages ?? const []);
    _messagesKey = null;
    _pushMessages(state);
    if (session != null) unawaited(_announce(runtime, session.id));
  }

  Future<void> _pushLocalization() async {
    final runtime = _runtime;
    if (runtime == null) return;
    final locale = _locale ?? 'en';
    final store = await ref.read(pluginStoreProvider.future);
    final builder = PluginRuntimePayloadBuilder(store: store);
    await runtime.updateLocalization([
      for (final plugin in ref.read(enabledPluginsProvider))
        {
          'pluginId': plugin.id,
          'i18n': plugin.catalogs.isEmpty
              ? null
              : plugin.localizer(locale).runtimeSnapshot(),
          'messageActions': await builder.messageActions(
            plugin,
            plugin.localizer(locale),
          ),
        },
    ]);
  }

  void _pushMessages(ChatState? state) {
    final runtime = _runtime;
    final session = state?.session;
    if (runtime == null) return;
    final busy =
        state == null ||
        state.isGenerating ||
        state.isSendPending ||
        state.isPostGenRunning;
    final list = [
      for (final m in session?.messages ?? const [])
        {'id': m.id, 'role': m.role == 'user' ? 'user' : 'character'},
    ];
    final key = '${session?.id}|$busy|${list.map((m) => m['id']).join(',')}';
    if (key == _messagesKey) return;
    _messagesKey = key;
    runtime.setMessages(list, busy: busy, chatId: session?.id);
  }

  void _onChatState(ChatState? state) {
    final runtime = _runtime;
    final host = _host;
    if (runtime == null || host == null || state == null) return;
    _pushMessages(state);
    final session = state.session;
    if (session?.id != _sessionId) {
      final previous = _sessionId;
      _sessionId = session?.id;
      _chatSignature = null;
      _snapshot = pluginMessageSignatures(session?.messages ?? const []);
      if (previous != null) {
        runtime.dispatchEvent('chat:closed', {'chatId': previous});
      }
      if (session != null) unawaited(_announce(runtime, session.id));
      return;
    }
    if (session == null || state.isGenerating || state.isSendPending) return;
    unawaited(_checkChatUpdated());
    final changes = diffPluginMessages(_snapshot, session.messages);
    if (changes.isEmpty) return;
    _snapshot = pluginMessageSignatures(session.messages);
    final deleted = <String>{};
    for (final change in changes) {
      if (change.change == 'deleted') deleted.add(change.id);
      runtime.dispatchEvent('message:${change.change}', {
        'chatId': session.id,
        'change': change.change,
        'message': change.message == null
            ? {'id': change.id}
            : messageJson(
                change.message!,
                index: change.index,
                characterId: widget.charId,
              ),
      });
    }
    if (deleted.isNotEmpty) {
      unawaited(
        host.variables
            .forgetMessages(session.id, deleted)
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> _announce(PluginChatRuntime runtime, String sessionId) async {
    final host = _host;
    if (host == null) return;
    for (final plugin in ref.read(enabledPluginsProvider)) {
      if (!plugin.allows(PluginPermission.variables)) continue;
      try {
        runtime.pushVars(
          plugin.id,
          'chat',
          await host.variables.read(plugin.id, 'chat', sessionId),
        );
      } catch (_) {
        // A session that vanished mid-switch has no variables to push.
      }
    }
    if (!identical(_runtime, runtime) || _sessionId != sessionId) return;
    final session = ref.read(chatProvider(widget.charId)).value?.session;
    if (session == null || session.id != sessionId) return;
    final chat = await chatJson(host, session);
    if (!identical(_runtime, runtime) || _sessionId != sessionId) return;
    _chatSignature = _signature(chat);
    runtime.dispatchEvent('chat:opened', {'chatId': sessionId, 'chat': chat});
  }

  /// The settings of a chat a change of which is worth a `chat:updated`;
  /// counts and times move with every message.
  static String _signature(Map<String, Object?> chat) => jsonEncode({
    for (final e in chat.entries)
      if (e.key != 'messageCount' && e.key != 'updatedAt') e.key: e.value,
  });

  /// Sends `chat:updated` when the open chat's name, persona, preset or
  /// lorebooks changed since it was last sent.
  Future<void> _checkChatUpdated() async {
    final runtime = _runtime;
    final host = _host;
    final sessionId = _sessionId;
    if (runtime == null || host == null || sessionId == null) return;
    if (_chatSignature == null) return;
    final session = ref.read(chatProvider(widget.charId)).value?.session;
    if (session == null || session.id != sessionId) return;
    final chat = await chatJson(host, session);
    if (!mounted || !identical(_runtime, runtime) || _sessionId != sessionId) {
      return;
    }
    final signature = _signature(chat);
    if (signature == _chatSignature) return;
    _chatSignature = signature;
    runtime.dispatchEvent('chat:updated', {'chatId': sessionId, 'chat': chat});
  }

  /// What the frames are built from. Permissions that ask are checked on
  /// each call, so switching them needs no restart.
  static String _runtimeKey(List<InstalledPlugin>? plugins) => jsonEncode([
    for (final x in plugins ?? const <InstalledPlugin>[])
      [
        x.id,
        x.installedAt,
        x.config,
        [
          for (final r in x.revoked.toList()..sort())
            if (!PluginPermission.asking.contains(r)) r,
        ],
        x.networkHosts?.toList()?..sort(),
        x.localNetwork,
      ],
  ]);

  @override
  Widget build(BuildContext context) {
    ref.listen(chatBridgeRegistryProvider(widget.charId), (prev, next) {
      if (!identical(prev, next)) unawaited(_restart());
    });
    ref.listen(enabledPluginsProvider, (prev, next) {
      if (_runtimeKey(prev) != _runtimeKey(next)) unawaited(_restart());
    });
    ref.listen(
      chatProvider(widget.charId),
      (_, next) => _onChatState(next.value),
    );
    // The chat's persona, preset and lorebooks live outside its session.
    ref.listen(personaConnectionsProvider, (_, _) => _checkChatUpdated());
    ref.listen(presetConnectionsProvider, (_, _) => _checkChatUpdated());
    ref.listen(lorebookActivationsProvider, (_, _) => _checkChatUpdated());
    return widget.child;
  }
}
