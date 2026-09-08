import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/models/character.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/persona.dart';
import '../../../core/models/preset.dart';
import '../../extensions/services/js_bridge_service.dart';
import 'chat_webview_environment.dart';
import 'chat_message_mapper.dart';
import 'bridge_handlers.dart';
import 'bridge_message_commands.dart';
import 'bridge_theme_commands.dart';
import 'bridge_identity_commands.dart';
import 'bridge_layout_commands.dart';
import 'bridge_memory_commands.dart';
import 'chat_overlay_blur_region.dart';

/// Bridge between the chat WebView (JS) and Flutter. Owns the shared
/// state (current character, persona, layout, memory coverage, regex
/// display config) and the JS handler registration. Splits outgoing
/// commands into focused groups:
///
///   - [messages]: set/append/update/remove messages, scroll helpers
///   - [theme]:    applyTheme, fonts, background image/noise, perf mode
///   - [identity]: setIdentity, applyLayout, regex context
///   - [layout]:   padding, search, edit, selection, message settings
///   - [memory]:   memory book data updates + covered/pending/draft sets
///
/// Inbound callbacks (JS -> Dart) are exposed as nullable function
/// properties on the host and registered via [setupHandlers].
class ChatBridgeController {
  static Set<String> get supportedExtensionMethods =>
      JsBridgeMethodRegistry.methodsFor(JsBridgeHostProfile.visual);

  final InAppWebViewController _controller;
  final JsBridgeService _jsBridgeService;
  final Map<String, Completer<dynamic>> _pendingRequests = {};

  String? currentCharName;
  String? currentCharColor;
  String? currentPersonaName;
  String? currentChatLayout;
  String? _charAvatarUrl;
  String? _personaAvatarUrl;
  int currentGreetingTotal = 0;
  bool isGenerating = false;
  bool isGeneratingImage = false;
  bool isPostGenRunning = false;
  final Set<String> _coveredMemoryIds = {};
  final Set<String> _pendingMemoryIds = {};
  final Set<String> _draftMemoryIds = {};
  final Map<String, String> _blockStatusByMessageId = {};
  final Map<String, List<TriggeredEntry>> _triggeredRegexesByMessageId = {};

  List<PresetRegex> _displayRegexes = [];
  Character? _regexCharacter;
  Persona? _regexPersona;

  /// Origin marker ("Created on" / "Branched on") for the current session,
  /// prepended by [MessageBridgeCommands.setMessages] as the first synthetic
  /// separator of a full batch. Refreshed on every rebuild before messages
  /// are dispatched. Null when the session has no usable timestamp.
  Map<String, Object?>? chatOrigin;

  late final MessageBridgeCommands messages = MessageBridgeCommands(this);
  late final ThemeBridgeCommands theme = ThemeBridgeCommands(this);
  late final IdentityBridgeCommands identity = IdentityBridgeCommands(this);
  late final LayoutBridgeCommands layout = LayoutBridgeCommands(this);
  late final MemoryBridgeCommands memory = MemoryBridgeCommands(this);

  ChatBridgeController(this._controller, this._jsBridgeService) {
    setupHandlers();
  }

  // Getters used by command groups. They intentionally expose mutable
  // internals so groups can read and update shared state without
  // bouncing every access through a getter method.
  String? get charAvatarUrl => _charAvatarUrl;
  String? get personaAvatarUrl => _personaAvatarUrl;
  Set<String> get coveredMemoryIds => _coveredMemoryIds;
  Set<String> get pendingMemoryIds => _pendingMemoryIds;
  Set<String> get draftMemoryIds => _draftMemoryIds;
  Map<String, String> get blockStatusByMessageId => _blockStatusByMessageId;
  List<PresetRegex> get displayRegexes => _displayRegexes;
  Character? get regexCharacter => _regexCharacter;
  Persona? get regexPersona => _regexPersona;
  JsBridgeService get extensionBridgeService => _jsBridgeService;

  List<TriggeredEntry> triggeredRegexesFor(String messageId) =>
      _triggeredRegexesByMessageId[messageId] ?? const [];

  void cacheMappedTriggeredRegexes(Map<String, dynamic> message) {
    final messageId = message['id'] as String?;
    if (messageId == null) return;
    final raw = message['triggeredRegexes'];
    if (raw is! List) {
      _triggeredRegexesByMessageId.remove(messageId);
      return;
    }
    _triggeredRegexesByMessageId[messageId] = raw
        .whereType<Map<String, dynamic>>()
        .map(TriggeredEntry.fromJson)
        .toList(growable: false);
  }

  void removeCachedTriggeredRegexes(String messageId) {
    _triggeredRegexesByMessageId.remove(messageId);
  }

  void clearCachedTriggeredRegexes() {
    _triggeredRegexesByMessageId.clear();
  }

  ChatMessageMapperContext get mapperContext => ChatMessageMapperContext(
    currentCharName: currentCharName,
    currentCharColor: currentCharColor,
    currentPersonaName: currentPersonaName,
    charAvatarDataUrl: _charAvatarUrl,
    personaAvatarDataUrl: _personaAvatarUrl,
    isGenerating: isGenerating,
    isPostGenRunning: isPostGenRunning,
    coveredMemoryIds: _coveredMemoryIds,
    pendingMemoryIds: _pendingMemoryIds,
    draftMemoryIds: _draftMemoryIds,
    greetingTotal: currentGreetingTotal,
    blockStatusByMessageId: Map.unmodifiable(_blockStatusByMessageId),
  );

  /// Builds the origin separator marker for [session], or null when it has no
  /// usable timestamp. A branched session (carrying a `branchedAt` session var)
  /// yields a "Branched on" marker; any other session falls back to a "Created
  /// on" marker derived from the first message's timestamp. Timestamps are in
  /// milliseconds to match [ChatMessage.timestamp] and the WebView's `new Date`.
  static Map<String, Object?>? originMarkerFor(ChatSession? session) {
    final event = session?.originEvent;
    if (event == null) return null;
    return {
      '__separator': true,
      'separatorKind': event.kind == ChatOriginKind.branched
          ? 'branched'
          : 'created',
      'timestamp': event.timestampMs,
    };
  }

  void setRegexContext(
    List<PresetRegex> regexes,
    Character? char,
    Persona? persona,
  ) {
    _displayRegexes = regexes;
    _regexCharacter = char;
    _regexPersona = persona;
  }

  void resolveRequest(String requestId, dynamic result) {
    final completer = _pendingRequests.remove(requestId);
    completer?.complete(result);
  }

  void rejectRequest(String requestId, String error) {
    final completer = _pendingRequests.remove(requestId);
    completer?.completeError(Exception(error));
  }

  Future<dynamic> requestFromJs(String requestId, Duration timeout) {
    final completer = Completer<dynamic>();
    _pendingRequests[requestId] = completer;
    Future.delayed(timeout, () {
      if (_pendingRequests.remove(requestId) != null) {
        completer.completeError(TimeoutException('Bridge request timed out'));
      }
    });
    return completer.future;
  }

  // ── Helpers used by command groups. Exposed as instance methods so
  // groups don't need to know about the InAppWebViewController or
  // private state of the host.

  Future<String> resolveImgResults(String text) async {
    return text.replaceAllMapped(
      RegExp(r'\[IMG:RESULT:([^\]|]+)(\|[^\]]*)?\]'),
      (match) {
        final path = match.group(1) ?? '';
        final suffix = match.group(2) ?? '';
        final resolved = resolveLocalFileUrl(path);
        return resolved == null ? '' : '[IMG:RESULT:$resolved$suffix]';
      },
    );
  }

  String? resolveLocalFileUrl(String? source) {
    return chatWebViewResolveLocalFileUrl(source);
  }

  String normalizeLayout(String? layout) {
    final raw = (layout ?? '').trim().toLowerCase();
    if (raw == 'bubble' || raw == 'bubbles') return 'bubble';
    return 'default';
  }

  void setAvatarUrl(String? path, {required bool isChar}) {
    final url = path == null || path.isEmpty ? null : resolveLocalFileUrl(path);
    if (isChar) {
      _charAvatarUrl = url;
    } else {
      _personaAvatarUrl = url;
    }
  }

  Future<void> callJs(String method, String arg) {
    return evalJs('window.bridge?.$method(${escapeJsonStr(arg)})');
  }

  Future<void> evalJs(String source) async {
    try {
      await _controller.evaluateJavascript(source: source);
    } on MissingPluginException {
      // The native WebView platform channel has already been torn down
      // (e.g. the chat screen was closed while a deferred panel-JS refresh
      // was still in flight). Nothing to update — swallow quietly instead
      // of logging a misleading "panel JS update failed" stack trace.
    }
  }

  Future<Object?> evalJsWithResult(String source) async {
    try {
      return await _controller.evaluateJavascript(source: source);
    } on MissingPluginException {
      return null;
    }
  }

  String escape(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n');
  }

  String escapeJsonStr(String s) {
    return '"${jsonEncode(s).substring(1, jsonEncode(s).length - 1)}"';
  }

  // ── Inbound callbacks (JS -> Dart). Set by the host (chat_webview_widget)
  // and forwarded to a typed bridge command when the user interacts with
  // the WebView.

  void Function()? onReady;
  void Function()? onLoadMore;
  void Function(bool hidden)? onHeaderScroll;
  void Function(bool visible)? onScrollToBottomVisibility;
  void Function(String url)? onLinkClick;
  void Function(String url)? onImageClick;
  void Function(String src)? onImgDownload;
  void Function(String id, bool isUser, bool isSystem, String content)?
  onMessageContext;
  void Function(String id, String direction)? onSwipe;
  void Function(String id, String direction)? onAgentSwipe;
  void Function(String id, int direction)? onChangeGreeting;
  void Function(String id, String mode)? onRegenerate;

  /// Called when the user taps the "Re-run cleaner" icon on an assistant
  /// message: re-runs POST-cleaner against that message's final (agentSwipes[0])
  /// text and appends a new 'cleaned' sub-swipe. Carries the message id.
  void Function(String messageId)? onRerunCleaner;
  void Function(String action, String text)? onSelectionAction;
  void Function(String id, String text)? onEditSave;
  void Function(String id)? onEditCancel;
  void Function(String id, bool focused)? onEditFocusChange;
  void Function(String id, String guidanceText)? onGuidedSwipe;
  void Function(String id)? onMemoryClick;
  void Function(String id)? onToggleHidden;

  /// Eye button on a message's image attachment: hides/shows the image for
  /// the model without touching the bubble itself. Carries the message id.
  void Function(String id)? onToggleImageHidden;
  void Function(List<String> ids)? onSelectionChange;
  void Function(String id)? onInjectClick;
  void Function(String instruction, String messageId)? onImgRetry;
  void Function(String instruction, String messageId)? onImgFind;
  void Function(String instruction, String messageId)? onImgRegen;
  void Function(String src, String instruction, String messageId)? onImgOptions;
  void Function()? onImgCancel;
  void Function()? onStop;
  void Function(String messageId)? onExtBlocksRunAll;
  void Function(String blockId, String messageId)? onExtBlockStop;
  void Function(String blockId, String messageId)? onExtBlockRegen;
  void Function(String blockId, String messageId)? onExtBlockRegenImage;
  void Function(String blockId, String messageId)? onExtBlockEdit;
  void Function(String blockId, String messageId)? onExtBlockDelete;

  /// Called when an interactive panel reports its content height changed.
  /// `panelId` identifies the panel, `messageId` the assistant message it
  /// belongs to, `heightPx` the new height in CSS pixels.
  void Function(String panelId, String messageId, double heightPx)?
  onPanelResize;

  /// Called when an interactive panel emits a custom event (action button,
  /// form submit, etc.). The `payload` shape is panel-defined.
  void Function(
    String panelId,
    String messageId,
    String event,
    Map<String, dynamic> payload,
  )?
  onPanelEvent;

  /// Register JS handlers for every callback declared on this host. The
  /// declarations live in [bridgeHandlers] (data-driven) so the actual
  /// dispatch table is short and auditable.
  void setupHandlers() {
    for (final entry in bridgeHandlers.entries) {
      final name = entry.key;
      final spec = entry.value;
      _controller.addJavaScriptHandler(
        handlerName: name,
        callback: (args) => _dispatch(name, spec, args),
      );
    }
    _controller.addJavaScriptHandler(
      handlerName: 'glazeBridge',
      callback: (args) async {
        final raw = args.isNotEmpty ? args.first : const <String, dynamic>{};
        final request = raw is Map<String, dynamic>
            ? raw
            : raw is Map
            ? Map<String, dynamic>.from(raw)
            : const <String, dynamic>{};
        return _jsBridgeService.dispatch(request);
      },
    );
  }

  dynamic _dispatch(String name, HandlerSpec spec, List<dynamic> args) {
    switch (spec.kind) {
      case HandlerKind.noArgs:
        return _dispatchNoArgs(name);
      case HandlerKind.boolArg:
        return _dispatchBoolArg(name, args);
      case HandlerKind.stringArg:
        return _dispatchStringArg(name, args);
      case HandlerKind.jsonObject:
        return _dispatchJsonObject(name, spec, args);
      case HandlerKind.idStringPair:
        return _dispatchIdStringPair(name, args);
      case HandlerKind.idIntPair:
        return _dispatchIdIntPair(name, args);
      case HandlerKind.idBoolPair:
        return _dispatchIdBoolPair(name, args);
      case HandlerKind.idStringStringPair:
        return _dispatchIdStringStringPair(name, args);
      case HandlerKind.imageAction:
        return _dispatchImageAction(name, spec, args);
      case HandlerKind.idList:
        return _dispatchIdList(name, args);
    }
  }

  void _dispatchNoArgs(String name) {
    switch (name) {
      case 'onWebViewReady':
        onReady?.call();
      case 'onLoadMore':
        onLoadMore?.call();
      case 'onStop':
        onStop?.call();
      case 'onImgCancel':
        onImgCancel?.call();
    }
  }

  void _dispatchBoolArg(String name, List<dynamic> args) {
    if (args.isEmpty) return;
    final v = args[0] == true;
    switch (name) {
      case 'onHeaderScroll':
        onHeaderScroll?.call(v);
      case 'onScrollToBottomVisibility':
        onScrollToBottomVisibility?.call(v);
    }
  }

  void _dispatchStringArg(String name, List<dynamic> args) {
    if (args.isEmpty) return;
    final s = args[0] as String;
    switch (name) {
      case 'onLinkClick':
        onLinkClick?.call(s);
      case 'onImageClick':
        onImageClick?.call(s);
      case 'onImgDownload':
        onImgDownload?.call(s);
      case 'onEditCancel':
        onEditCancel?.call(s);
      case 'onMemoryClick':
        onMemoryClick?.call(s);
      case 'onToggleHidden':
        onToggleHidden?.call(s);
      case 'onToggleImageHidden':
        onToggleImageHidden?.call(s);
      case 'onInjectClick':
        onInjectClick?.call(s);
      case 'onExtBlocksRunAll':
        onExtBlocksRunAll?.call(s);
      case 'onRerunCleaner':
        onRerunCleaner?.call(s);
    }
  }

  void _dispatchJsonObject(String name, HandlerSpec spec, List<dynamic> args) {
    if (args.isEmpty) return;
    try {
      final data = jsonDecode(args[0] as String) as Map<String, dynamic>;
      switch (name) {
        case 'onMessageContext':
          onMessageContext?.call(
            data['id'] as String? ?? '',
            data['isUser'] as bool? ?? false,
            data['isSystem'] as bool? ?? false,
            data['content'] as String? ?? '',
          );
        case 'onSwipe':
          onSwipe?.call(
            data['id'] as String? ?? '',
            data['direction'] as String? ?? 'left',
          );
        case 'onAgentSwipe':
          onAgentSwipe?.call(
            data['id'] as String? ?? '',
            data['direction'] as String? ?? 'left',
          );
        case 'onSelectionAction':
          onSelectionAction?.call(
            data['action'] as String? ?? 'copy',
            data['text'] as String? ?? '',
          );
        case 'onPanelResize':
          final panelId = data['panelId'] as String? ?? '';
          final height = (data['height'] as num?)?.toDouble() ?? 0.0;
          if (panelId.isEmpty) return;
          onPanelResize?.call(panelId, '', height);
        case 'onImgOptions':
          onImgOptions?.call(
            data['src'] as String? ?? '',
            data['instruction'] as String? ?? '',
            data['messageId'] as String? ?? '',
          );
        case 'onPanelEvent':
          final panelId = data['panelId'] as String? ?? '';
          final event = data['event'] as String? ?? 'action';
          final payloadRaw = data['payload'];
          final payload = payloadRaw is Map
              ? Map<String, dynamic>.from(payloadRaw)
              : <String, dynamic>{};
          if (panelId.isEmpty) return;
          onPanelEvent?.call(panelId, '', event, payload);
      }
    } catch (_) {}
  }

  void _dispatchIdStringPair(String name, List<dynamic> args) {
    if (args.length < 2) return;
    final id = args[0] as String? ?? '';
    final s = args[1] as String? ?? '';
    switch (name) {
      case 'onEditSave':
        onEditSave?.call(id, s);
      case 'onRegenerate':
        onRegenerate?.call(id, s);
    }
  }

  void _dispatchIdIntPair(String name, List<dynamic> args) {
    if (args.length < 2) return;
    final id = args[0] as String? ?? '';
    final dir = args[1] is int
        ? args[1] as int
        : int.tryParse('${args[1]}') ?? 0;
    if (id.isEmpty || dir == 0) return;
    switch (name) {
      case 'onChangeGreeting':
        onChangeGreeting?.call(id, dir);
    }
  }

  void _dispatchIdBoolPair(String name, List<dynamic> args) {
    if (args.length < 2) return;
    final id = args[0] as String? ?? '';
    final v = args[1] == true;
    switch (name) {
      case 'onEditFocusChange':
        onEditFocusChange?.call(id, v);
    }
  }

  void _dispatchIdStringStringPair(String name, List<dynamic> args) {
    if (args.length < 2) return;
    final id = args[0] as String? ?? '';
    final s = args[1] as String? ?? '';
    switch (name) {
      case 'onGuidedSwipe':
        onGuidedSwipe?.call(id, s);
    }
  }

  void _dispatchImageAction(String name, HandlerSpec spec, List<dynamic> args) {
    if (args.length < 2) return;
    final instr = args[0] as String? ?? '';
    final msgId = args[1] as String? ?? '';
    if (spec.debugPrint != null) {
      debugPrint(spec.debugPrint!.replaceAll('\$args', args.toString()));
    }
    switch (name) {
      case 'onImgRetry':
        onImgRetry?.call(instr, msgId);
      case 'onImgFind':
        onImgFind?.call(instr, msgId);
      case 'onImgRegen':
        onImgRegen?.call(instr, msgId);
      case 'onExtBlockStop':
        onExtBlockStop?.call(instr, msgId);
      case 'onExtBlockRegen':
        onExtBlockRegen?.call(instr, msgId);
      case 'onExtBlockRegenImage':
        onExtBlockRegenImage?.call(instr, msgId);
      case 'onExtBlockEdit':
        onExtBlockEdit?.call(instr, msgId);
      case 'onExtBlockDelete':
        onExtBlockDelete?.call(instr, msgId);
    }
  }

  void _dispatchIdList(String name, List<dynamic> args) {
    if (args.isEmpty) return;
    try {
      final list = jsonDecode(args[0] as String) as List;
      switch (name) {
        case 'onSelectionChange':
          onSelectionChange?.call(list.cast<String>());
      }
    } catch (_) {}
  }

  // ── Outgoing-command facade. These methods exist so existing callers
  // in chat_webview_widget.dart (and elsewhere) can keep using
  // _bridge!.setMessages(...), _bridge!.applyTheme(...) without knowing
  // about the new group structure. Each call delegates to the
  // corresponding group instance. They are intentionally one-liners
  // so the host stays a thin facade; new code should prefer the
  // group property directly: _bridge.messages.setMessages(...).

  // Messages
  Future<void> setMessages(
    List<ChatMessage> m, {
    int visibleStartIndex = 0,
    bool preserveScroll = false,
  }) => messages.setMessages(
    m,
    visibleStartIndex: visibleStartIndex,
    preserveScroll: preserveScroll,
  );
  Future<void> appendMessage(ChatMessage m) => messages.appendMessage(m);
  Future<void> appendMessages(List<ChatMessage> m, {int startIndex = 0}) =>
      messages.appendMessages(m, startIndex: startIndex);
  Future<void> prependMessages(
    List<ChatMessage> m, {
    int visibleStartIndex = 0,
  }) => messages.prependMessages(m, visibleStartIndex: visibleStartIndex);
  Future<void> updateMessage(
    ChatMessage m, {
    bool isStreamingUpdate = false,
    bool isLast = false,
  }) => messages.updateMessage(
    m,
    isStreamingUpdate: isStreamingUpdate,
    isLast: isLast,
  );
  Future<void> updateMessageContent(String id, String text, bool isUser) =>
      messages.updateMessageContent(id, text, isUser);
  Future<void> removeMessage(String id) => messages.removeMessage(id);
  Future<void> setLastMessage(String? id) => messages.setLastMessage(id);
  Future<void> clearAll() => messages.clearAll();
  Future<void> scrollToBottom({bool smooth = false}) =>
      messages.scrollToBottom(smooth: smooth);
  Future<void> requestScrollToBottomOnAppend() =>
      messages.requestScrollToBottomOnAppend();
  Future<void> scrollToMessage(String id, {bool highlight = false}) =>
      messages.scrollToMessage(id, highlight: highlight);
  Future<void> showHeader() => messages.showHeader();

  // Theme
  Future<void> setBackgroundNoise(double opacity, double intensity) =>
      theme.setBackgroundNoise(opacity, intensity);
  Future<void> setBackgroundImage(String? src, int blur, double opacity) =>
      theme.setBackgroundImage(src, blur, opacity);
  Future<void> setChatFont({
    String? fontName,
    String? fontDataUrl,
    required double fontSize,
    required double letterSpacing,
  }) => theme.setChatFont(
    fontName: fontName,
    fontDataUrl: fontDataUrl,
    fontSize: fontSize,
    letterSpacing: letterSpacing,
  );
  Future<void> applyTheme(Map<String, String> t) => theme.applyTheme(t);
  Future<void> setPerformanceMode(bool enabled) =>
      theme.setPerformanceMode(enabled);

  // Identity
  Future<void> setIdentity({
    String? charName,
    String? charColor,
    String? personaName,
    String? layout,
    String? charAvatarPath,
    String? personaAvatarPath,
    int? greetingTotal,
  }) => identity.setIdentity(
    charName: charName,
    charColor: charColor,
    personaName: personaName,
    layout: layout,
    charAvatarPath: charAvatarPath,
    personaAvatarPath: personaAvatarPath,
    greetingTotal: greetingTotal,
  );
  Future<void> applyLayout(String l) => identity.applyLayout(l);

  // Layout
  Future<void> setSearch({required String query, int activeIndex = -1}) =>
      layout.setSearch(query: query, activeIndex: activeIndex);
  Future<void> setBottomPadding(double px, {double viewportHeight = 0}) =>
      layout.setBottomPadding(px, viewportHeight: viewportHeight);
  Future<void> setTopPadding(double px) => layout.setTopPadding(px);
  Future<void> setOverlayBlurRegions(List<ChatOverlayBlurRegion> regions) =>
      layout.setOverlayBlurRegions(regions);
  Future<void> startEdit(String id) => layout.startEdit(id);
  Future<void> stopEdit(String id) => layout.stopEdit(id);
  Future<void> setMessageSettings({
    required bool batterySaver,
    required bool hideMessageId,
    required bool hideGenerationTime,
    required bool hideTokenCount,
    required bool disableSwipeRegeneration,
    required bool studioEnabled,
  }) => layout.setMessageSettings(
    batterySaver: batterySaver,
    hideMessageId: hideMessageId,
    hideGenerationTime: hideGenerationTime,
    hideTokenCount: hideTokenCount,
    disableSwipeRegeneration: disableSwipeRegeneration,
    studioEnabled: studioEnabled,
  );
  Future<void> setSelectionMode(bool enabled) =>
      layout.setSelectionMode(enabled);
  Future<void> toggleMessageSelection(String id) =>
      layout.toggleMessageSelection(id);

  // Memory
  void updateMemoryBookData({
    required List<Map<String, dynamic>> entries,
    required List<Map<String, dynamic>> pendingDrafts,
  }) => memory.updateMemoryBookData(
    entries: entries,
    pendingDrafts: pendingDrafts,
  );

  // Ext Blocks

  /// Sends block panel data to JS so the inline panel renders/updates.
  Future<void> showExtBlocksPanel(
    String messageId,
    List<Map<String, dynamic>> blocks, {
    bool canRunAll = false,
  }) async {
    final resolvedBlocks = await Future.wait(
      blocks.map(_resolveExtBlockContent),
    );
    final payload = jsonEncode({
      'messageId': messageId,
      'blocks': resolvedBlocks,
      'canRunAll': canRunAll,
    });
    await callJs('showExtBlocksPanel', payload);
  }

  Future<void> hideExtBlocksPanel(String messageId) async {
    await callJs('hideExtBlocksPanel', messageId);
  }

  /// Updates only one block's body in an existing panel (streaming).
  /// Returns false when the panel or block row is missing — caller should
  /// fall back to [showExtBlocksPanel].
  Future<bool> patchExtBlockContent({
    required String messageId,
    required String blockId,
    required String content,
    required String status,
  }) async {
    final resolvedContent = await resolveImgResults(content);
    final payload = jsonEncode({
      'messageId': messageId,
      'blockId': blockId,
      'content': resolvedContent,
      'status': status,
    });
    final result = await evalJsWithResult(
      'window.bridge?.patchExtBlockContent(${escapeJsonStr(payload)})',
    );
    return result == true || result == 'true';
  }

  Future<Map<String, dynamic>> _resolveExtBlockContent(
    Map<String, dynamic> block,
  ) async {
    final copy = Map<String, dynamic>.from(block);
    final content = copy['content'];
    if (content is String) {
      copy['content'] = await resolveImgResults(content);
    }
    return copy;
  }

  Future<void> updateBlockStatus(String messageId, String? status) async {
    // Badge UX removed — block status is shown inline in the ext-blocks panel.
  }

  // ── Interactive panels ────────────────────────────────────────────────

  /// Opens a persistent sandboxed iframe island under [messageId] and renders
  /// [html] inside it. Returns the panelId assigned by JS, or `null` when
  /// the message isn't currently in the DOM.
  ///
  /// [options] is a free-form JSON object. Recognised keys:
  ///   - `title`: aria-label / accessibility hint for the iframe
  ///   - `minHeight`: starting height in pixels (default 120, clamped 60..2000)
  Future<String?> openInteractivePanel({
    required String messageId,
    required String html,
    Map<String, dynamic> options = const {},
  }) async {
    await _ensureGlazeSdkLoaded();
    final raw = await evalJsWithResult(
      'window.bridge?.openPanel(${escapeJsonStr(messageId)}, ${escapeJsonStr(html)}, ${escapeJsonStr(jsonEncode(options))})',
    );
    if (raw is String && raw.isNotEmpty) return raw;
    return null;
  }

  /// Closes an open panel. No-op if the panel doesn't exist.
  Future<void> closeInteractivePanel(String panelId) async {
    if (panelId.isEmpty) return;
    await callJs('closePanel', panelId);
  }

  /// Closes all panels currently open in the WebView. Called on session
  /// switch and full reset to avoid leaking iframes between sessions.
  Future<void> closeAllInteractivePanels() async {
    await evalJs('window.bridge?._panelHost?.closeAll()');
  }

  /// Pushes a `glaze:panel-push` message to the panel iframe (no response
  /// expected). Useful for live updates from Dart.
  Future<bool> postToInteractivePanel({
    required String panelId,
    required String method,
    Map<String, dynamic> params = const {},
  }) async {
    if (panelId.isEmpty) return false;
    final result = await evalJsWithResult(
      'window.bridge?.postToPanel(${escapeJsonStr(panelId)}, ${escapeJsonStr(method)}, ${escapeJsonStr(jsonEncode(params))})',
    );
    return result == true || result == 'true';
  }

  Future<void> _ensureGlazeSdkLoaded() async {
    final existing = await evalJsWithResult('typeof window.__glazeSdkSource');
    if (existing == 'string') return;
    final sdkSource = await rootBundle.loadString(
      'assets/chat_webview/glaze_sdk.js',
    );
    await _controller.evaluateJavascript(
      source: 'window.__glazeSdkSource = ${escapeJsonStr(sdkSource)};',
    );
  }

  /// Runs [script] inside a sandboxed iframe in the Chat WebView and returns
  /// the string result. Throws on timeout (>60 s) or script error.
  ///
  /// Context passed to the script:
  ///   - messages: last [contextMessageCount] messages (role + text)
  ///   - character: name, description, personality, scenario
  ///   - previousOutput: output of the previous block in the chain (or null)
  Future<String> runJsBlock({
    required String script,
    required List<ChatMessage> messages,
    required Character? character,
    required String? sessionId,
    required String? previousOutput,
    int contextMessageCount = 10,
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled == true) {
      throw Exception('Cancelled before JS execution');
    }

    // Build context object for the script.
    final int take = contextMessageCount < 0
        ? messages.length
        : contextMessageCount;
    final startIdx = (messages.length - take).clamp(0, messages.length);
    final contextMessages = messages
        .sublist(startIdx)
        .map((m) => {'role': m.role, 'text': m.content})
        .toList();

    final contextMap = <String, dynamic>{
      'messages': contextMessages,
      'sessionId': sessionId,
      'characterId': character?.id,
      'character': character != null
          ? {
              'name': character.name,
              'description': character.description ?? '',
              'personality': character.personality ?? '',
              'scenario': character.scenario ?? '',
            }
          : null,
      'previousOutput': previousOutput,
    };
    final contextJson = jsonEncode(contextMap);

    final sdkSource = await rootBundle.loadString(
      'assets/chat_webview/glaze_sdk.js',
    );
    await _controller.evaluateJavascript(
      source: 'window.__glazeSdkSource = ${escapeJsonStr(sdkSource)};',
    );

    // callAsyncJavaScript returns the JS Promise result.
    // bridge.runSandboxedScript returns a Promise<string>.
    final result = await _controller
        .callAsyncJavaScript(
          functionBody: '''
        return window.bridge.runSandboxedScript(script, contextJson);
      ''',
          arguments: {'script': script, 'contextJson': contextJson},
        )
        .timeout(
          const Duration(seconds: 60),
          onTimeout: () => throw TimeoutException(
            'JS runner timed out',
            const Duration(seconds: 60),
          ),
        );

    if (result == null) return '';
    final value = result.value;
    if (value is String) return value;
    return value?.toString() ?? '';
  }
}
