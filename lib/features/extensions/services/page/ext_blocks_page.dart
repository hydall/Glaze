/// The ExtBlocks page: a page over the chat where the scripts of the original
/// ExtBlocks extension run when the active preset may use it
/// ([PresetPermissions.chatPage]).
///
/// The original evaluates a script in SillyTavern's own page, so what a script
/// leaves behind — a floating button, a window, a timer — stays, and what it
/// keeps in `localStorage` is there next time. Glaze's script sandbox is a
/// hidden frame thrown away when the script returns, which drops all of that.
///
/// The page is a chat panel of a plugin the app makes itself
/// ([extBlocksPagePlugin]), so it gets what plugins already have: a frame
/// with no origin of its own under a content policy, a place over the chat
/// (the plugin layer) where only the boxes it draws take touches, and a
/// `localStorage` the app keeps. On it:
///
/// - scripts run through `action:extblocks:run`, with the same `context` and
///   scope as in the sandbox (`extblocks_compat.js`), and their `glaze.*`
///   calls go to the chat's [JsBridgeService] under the preset's permissions
///   (`extblocks.bridge`);
/// - the chat is mirrored, hidden, in SillyTavern's markup
///   (`#chat .mes[mesid] .mes_text`), as the messages are displayed, so a
///   script reading the chat finds what it looks for;
/// - when the page opens, the preset's scripts run once more to restore what
///   they draw; on that run they may not generate or write.
///
/// Internet access follows "Allow external media", the setting that already
/// decides what the chat itself may load from outside.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/llm/regex_service.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/state/character_provider.dart';
import '../../../../core/state/persona_resolution.dart';
import '../../../chat/bridge/chat_bridge_controller.dart';
import '../../../chat/bridge/chat_bridge_registry.dart';
import '../../../chat/bridge/chat_message_mapper.dart';
import '../../../chat/bridge/chat_webview_environment.dart';
import '../../../chat/chat_provider.dart';
import '../../../image_gen/services/image_tag_markup.dart';
import '../../../plugins/models/installed_plugin.dart';
import '../../../plugins/models/plugin_manifest.dart';
import '../../../plugins/runtime/plugin_api.dart';
import '../../../plugins/runtime/plugin_chat_runtime.dart';
import '../../../plugins/runtime/plugin_file_store.dart';
import '../../models/block_config.dart';
import '../../models/block_modes.dart';
import '../../providers/info_blocks_provider.dart';
import '../../providers/preset_permissions_provider.dart';
import '../blocks/ext_blocks_script_scope.dart';
import '../card_blocks.dart';

/// The page's plugin id. A manifest id must start with a letter or digit, so
/// no installed plugin can take it (or its data folder).
const kExtBlocksPagePluginId = '_extblocks';

/// The compat layer the page loads after the plugin SDK
/// (`assets/chat_webview/plugins/compat/extblocks_page.js`).
const kExtBlocksPageCompat = 'extblocks';

/// What exposes `extblocks.bridge`; only the page's manifest lists it, and
/// the method checks the caller's id as well.
const kExtBlocksPagePermission = 'extblocks.page';

const _runEvent = 'action:extblocks:run';
const _mirrorEvent = 'extblocks:mirror';

/// The plugin the page runs as.
final InstalledPlugin extBlocksPagePlugin = InstalledPlugin(
  manifest: const PluginManifest(
    format: 1,
    id: kExtBlocksPagePluginId,
    name: PluginText.literal('ExtBlocks'),
    version: '1.0.0',
    raw: {},
    compat: kExtBlocksPageCompat,
    permissions: [kExtBlocksPagePermission],
    panels: [
      PluginPanel(
        id: 'page',
        src: 'page.html',
        placement: PluginPanelPlacement.chat,
      ),
    ],
  ),
  directory: '',
  enabled: true,
  installedAt: 0,
);

/// Whether the active preset runs its scripts on the page.
final extBlocksPageActiveProvider = Provider<bool>(
  (ref) => ref.watch(activePresetPermissionsProvider).chatPage,
);

/// The plugin method the page's `glaze.*` calls arrive through.
Map<String, PluginMethod> extBlocksPageApi() => {
  'extblocks.bridge': const PluginMethod(
    _bridge,
    exposedBy: [kExtBlocksPagePermission],
  ),
};

/// Hands a script's `glaze.*` call to the chat's [JsBridgeService], which
/// checks it against the active preset's permissions. The chat it is for is
/// the one the page is in, whatever the script says.
Future<Object?> _bridge(PluginCall c) async {
  if (c.plugin.id != kExtBlocksPagePluginId) {
    throw const PluginApiError('permission_denied', 'Not available');
  }
  final bridge = c.ref.read(chatBridgeRegistryProvider(c.host.charId));
  if (bridge == null) {
    throw const PluginApiError('unavailable', 'The chat is not open');
  }
  final request = c.mapArg(0);
  final context = request['context'];
  return bridge.extensionBridgeService.dispatch({
    'id': request['id'],
    'method': request['method'],
    'params': request['params'] ?? const <String, dynamic>{},
    'context': {
      if (context is Map) ...Map<String, dynamic>.from(context),
      'sessionId': c.host.sessionId,
      'characterId': c.host.charId,
    },
  });
}

/// The compat layer with the script API and the original's scope in it.
Future<String> extBlocksPageCompatSource() async {
  final page = await rootBundle.loadString(
    'assets/chat_webview/plugins/compat/extblocks_page.js',
  );
  final sdk = await rootBundle.loadString('assets/chat_webview/glaze_sdk.js');
  final compat = await rootBundle.loadString(
    'assets/chat_webview/extblocks_compat.js',
  );
  return page
      .replaceFirst('__XB_COMPAT__', jsonEncode(compat))
      .replaceFirst('/*__GLAZE_SDK__*/', sdk);
}

/// The page's entry in the plugin runtime's setup payload.
Future<Map<String, Object?>> extBlocksPageEntry({
  required PluginFileStore files,
  required bool allowExternalMedia,
}) async {
  final fileOrigin = chatWebViewLocalFileOrigin();
  return {
    'pluginId': kExtBlocksPagePluginId,
    'compat': kExtBlocksPageCompat,
    // Nothing to serve: the page is made inline.
    'package': null,
    'mainPath': null,
    'onePage': true,
    'main': null,
    'panels': [
      for (final panel in extBlocksPagePlugin.manifest.panels)
        {...panel.toJson(), 'html': '', 'order': 0},
    ],
    'config': const <String, Object?>{},
    'i18n': null,
    'vars': const {'chat': <String, dynamic>{}, 'global': <String, dynamic>{}},
    'storage': await files.readStorage(),
    'storageQuota': PluginFileStore.maxStorageBytes,
    'methods': extBlocksPageApi().keys.toList(),
    'events': const <String>[],
    'network': allowExternalMedia,
    'localNetwork': false,
    'messageActions': const <Object>[],
    // The chat's generated pictures, which the mirror shows.
    'mediaOrigins': [?fileOrigin],
  };
}

/// Whether [block] is a script the page runs: JavaScript the block carries.
/// A script the model writes keeps running in the sandbox.
bool runsOnExtBlocksPage(BlockConfig block) =>
    block.type == BlockType.script &&
    block.source == BlockSource.carried &&
    block.scriptType == ScriptType.js;

/// The page of one chat: runs scripts on it and keeps its mirror of the chat
/// in step.
class ExtBlocksPage {
  ExtBlocksPage({
    required this.runtime,
    required this.bridge,
    required this.charId,
    required this.read,
  });

  final PluginChatRuntime runtime;
  final ChatBridgeController bridge;
  final String charId;
  final ProviderRead read;

  static const _debounce = Duration(milliseconds: 300);

  Timer? _timer;
  bool _disposed = false;
  String? _sessionId;

  /// What the page holds, by message id: the key the html was built from.
  Map<String, String> _sent = const {};
  List<String> _order = const [];

  /// Built html by key, so a message is only rendered again when it changed.
  final Map<String, String> _html = {};

  /// Brings the mirror up to date soon; many changes in a row send once.
  void schedule() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(_debounce, flush);
  }

  /// Brings the mirror up to date now.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_disposed) return;
    final state = read(chatProvider(charId)).value;
    final session = state?.session;
    final reset = session?.id != _sessionId;
    if (reset) {
      _sessionId = session?.id;
      _sent = const {};
      _order = const [];
      _html.clear();
    }
    final messages = session?.messages ?? const <ChatMessage>[];
    final next = <String, String>{};
    final upsert = <Map<String, Object?>>[];
    final used = <String>{};
    for (final (index, m) in messages.indexed) {
      final inline = bridge.inlineExtBlocks(m);
      final key =
          '${m.swipeId}|${m.agentSwipeId}|${m.content.hashCode}|'
          '${m.content.length}|${inline.hashCode}|${inline.length}';
      next[m.id] = key;
      used.add(key);
      if (_sent[m.id] == key) continue;
      final html = _html[key] ??= _displayHtml(m, inline);
      upsert.add({
        'id': m.id,
        'index': index,
        'isUser': m.role == 'user',
        'name': m.role == 'user'
            ? (bridge.regexPersona?.name ?? m.personaName ?? 'User')
            : (bridge.regexCharacter?.name ?? ''),
        'html': html,
      });
    }
    _html.removeWhere((key, _) => !used.contains(key));
    final order = [for (final m in messages) m.id];
    if (!reset && upsert.isEmpty && listEquals(order, _order)) return;
    _sent = next;
    _order = order;
    runtime.emitTo(kExtBlocksPagePluginId, _mirrorEvent, {
      'reset': reset,
      'order': order,
      'upsert': upsert,
    });
  }

  /// The message as the chat displays it, before markdown: the text with its
  /// inline blocks, macros and display regexes, its pictures at URLs the page
  /// can load.
  String _displayHtml(ChatMessage m, String inline) {
    final character = bridge.regexCharacter;
    final persona = bridge.regexPersona;
    var text = ChatMessageMapper.displaySource(
      m,
      character: character,
      persona: persona,
      sessionVars: bridge.regexSessionVars,
      globalVars: bridge.regexGlobalVars,
      inlineExtBlocks: inline,
    );
    final regexes = bridge.displayRegexes;
    if (regexes.isNotEmpty) {
      text = applyRegexes(
        text,
        ChatMessageMapper.regexPlacement(m),
        1,
        regexes,
        ChatMessageMapper.regexContext(
          character: character,
          persona: persona,
          sessionVars: bridge.regexSessionVars,
          globalVars: bridge.regexGlobalVars,
        ),
        isMarkdown: true,
      );
    }
    // A picture the page cannot load still leaves its element for a script
    // to find.
    return ImageTagMarkup.rewriteResultPaths(
      text,
      (path) => chatWebViewResolveLocalFileUrl(path) ?? path,
    );
  }

  /// Runs [script] on the page with [context] (see
  /// [ChatBridgeController.jsBlockContext]) and returns what it returned.
  /// The mirror is brought up to date first, so the script reads the chat
  /// as it is now — a block that just finished included.
  Future<String> run(
    String script,
    Map<String, dynamic> context,
    CancelToken? cancelToken, {
    bool restore = false,
  }) async {
    if (_disposed) throw StateError('The ExtBlocks page is closed');
    if (cancelToken?.isCancelled == true) {
      throw Exception('Cancelled before JS execution');
    }
    flush();
    final result = await runtime.runAction(
      kExtBlocksPagePluginId,
      _runEvent,
      args: {'script': script, 'context': context, 'restore': restore},
    );
    if (!result.ok) {
      throw StateError(result.message ?? result.reason ?? 'Script failed');
    }
    final value = result.value;
    return value == null ? '' : value.toString();
  }

  /// Runs the preset's scripts once on a page that just opened, so what they
  /// draw is back — as it would still be on the original's page, which
  /// outlives a chat. They may not generate or write on this run.
  Future<void> restore() async {
    final session = read(chatProvider(charId)).value?.session;
    final preset = effectiveExtBlocksPreset(read, charId);
    if (session == null || preset == null || session.messages.isEmpty) return;
    final blocks =
        preset.blocks
            .where(
              (b) =>
                  b.enabled &&
                  !b.manualOnly &&
                  b.trigger != BlockTrigger.periodic &&
                  (b.triggerOnChar || b.triggerOnUser) &&
                  runsOnExtBlocksPage(b) &&
                  b.script.trim().isNotEmpty,
            )
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    if (blocks.isEmpty) return;
    final character = read(characterByIdProvider(charId));
    final persona = read(
      effectivePersonaForChatProvider((charId: charId, sessionId: session.id)),
    );
    for (final block in blocks) {
      if (_disposed) return;
      try {
        await run(
          block.script,
          ChatBridgeController.jsBlockContext(
            messages: session.messages,
            character: character,
            sessionId: session.id,
            previousOutput: null,
            contextMessageCount: block.contextMessageCount,
            extBlocks: extBlocksScriptScope(
              preset: preset,
              messages: session.messages,
              messageId: null,
              rows: read(infoBlocksProvider(session.id)),
              character: character,
              persona: persona,
            ),
          ),
          null,
          restore: true,
        );
      } catch (e) {
        debugPrint('[ExtBlocksPage] restoring "${block.name}" failed: $e');
      }
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
