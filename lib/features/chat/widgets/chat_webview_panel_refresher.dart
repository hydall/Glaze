import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/persona_resolution.dart';
import '../../extensions/providers/info_blocks_provider.dart';
import '../../extensions/services/ext_blocks_panel_builder.dart';
import '../../extensions/services/macro_expander.dart';
import '../bridge/chat_bridge_controller.dart';

/// Refresh / sync helpers for the inline ext-block panels rendered
/// by the chat WebView. Extracted from `chat_webview_widget.dart` so
/// the widget only calls `refreshForMessage` and `syncForSession`
/// without owning the panel-visibility / panel-blocks Riverpod lookups.
///
/// Pure functions on top of a [WidgetRef] and a [ChatBridgeController]
/// reference. The `ready` getter guards the bridge-dependent paths.
class ChatWebViewPanelRefresher {
  ChatWebViewPanelRefresher({
    required this.ref,
    required this.bridge,
    required this.ready,
    required this.isMounted,
    required this.charId,
    required this.messages,
  });

  final WidgetRef ref;
  final ChatBridgeController? bridge;
  final bool Function() ready;

  /// Guards every `ref` access. The refresher is driven by async provider
  /// listeners and `await` continuations that can fire after the owning
  /// widget has been disposed (e.g. closing the chat while a message-action
  /// menu refresh is in flight). Reading `ref` then throws
  /// "Using \"ref\" when a widget is about to or has been unmounted".
  final bool Function() isMounted;
  final String charId;
  final List<ChatMessage> Function() messages;

  /// Refresh the ext-block panel for a single message: hide it if the
  /// `extBlocksPanelVisibleProvider` says so, otherwise show with the
  /// current blocks / canRunAll from Riverpod.
  Future<void> refreshForMessage(String sessionId, String messageId) async {
    final b = bridge;
    if (b == null || !ready() || !isMounted()) return;
    final isLastAssistant = messageId == _lastAssistantMessageId();
    final swipeId = _swipeIdForMessage(messageId);
    final agentSwipeId = _agentSwipeIdForMessage(messageId);
    final isGreeting = _isGreetingMessage(messageId);
    final isAssistant = _isAssistantMessage(messageId);
    final panelKey = (
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    final visibilityKey = (
      sessionId: sessionId,
      messageId: messageId,
      isAssistant: isAssistant,
      isLastAssistant: isLastAssistant,
      isGreeting: isGreeting,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    if (!ref.read(extBlocksPanelVisibleProvider(visibilityKey))) {
      await b.hideExtBlocksPanel(messageId);
      return;
    }
    final blocks = _expandBlockPayloads(
      ref.read(extBlocksPanelBlocksProvider(panelKey)),
      sessionId,
    );
    final canRunAll = ref.read(extBlocksPanelCanRunAllProvider(panelKey));
    await b.showExtBlocksPanel(messageId, blocks, canRunAll: canRunAll);
  }

  /// Refresh the ext-block panel for every assistant/character message
  /// in the current chat. Used after a session switch and after any
  /// ext-block DB change.
  Future<void> syncForSession(String? sessionId) async {
    final sid = sessionId;
    if (sid == null || sid.isEmpty) return;
    final b = bridge;
    if (b == null || !ready() || !isMounted()) return;
    await ref.read(infoBlocksProvider(sid).notifier).refresh();
    // The refresh above is async; the widget may have been disposed while it
    // ran. Bail before touching `ref` again (refreshForMessage reads providers).
    if (!isMounted()) return;
    for (final msg in messages()) {
      if (msg.role != 'assistant' && msg.role != 'character') continue;
      await refreshForMessage(sid, msg.id);
    }
  }

  List<Map<String, dynamic>> _expandBlockPayloads(
    List<Map<String, dynamic>> blocks,
    String sessionId,
  ) {
    final character = ref.read(characterByIdProvider(charId));
    final persona = ref.read(
      effectivePersonaForChatProvider((charId: charId, sessionId: sessionId)),
    );
    final macroCtx = MacroContext(character: character, persona: persona?.name);
    return [
      for (final block in blocks)
        {
          ...block,
          if (block['content'] is String)
            'content': expand(block['content'] as String, macroCtx),
        },
    ];
  }

  int _swipeIdForMessage(String messageId) {
    final msg = messages().where((m) => m.id == messageId).firstOrNull;
    return msg?.swipeId ?? 0;
  }

  int _agentSwipeIdForMessage(String messageId) {
    final msg = messages().where((m) => m.id == messageId).firstOrNull;
    return msg?.agentSwipeId ?? -1;
  }

  bool _isGreetingMessage(String messageId) {
    final msg = messages().where((m) => m.id == messageId).firstOrNull;
    return msg?.greetingIndex != null;
  }

  bool _isAssistantMessage(String messageId) {
    final msg = messages().where((m) => m.id == messageId).firstOrNull;
    return msg?.role == 'assistant' || msg?.role == 'character';
  }

  String? _lastAssistantMessageId() {
    for (int i = messages().length - 1; i >= 0; i--) {
      final m = messages()[i];
      if (m.role == 'assistant' || m.role == 'character') return m.id;
    }
    return null;
  }
}
