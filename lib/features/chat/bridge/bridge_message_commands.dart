import 'dart:convert';

import '../../../core/models/chat_message.dart';
import 'chat_message_mapper.dart';
import 'chat_bridge_controller.dart';

/// Outgoing chat-message commands (Dart -> JS). All message rendering
/// goes through this group: bulk replace, append, prepend, update,
/// remove, plus scroll helpers. The mapper is invoked here to convert
/// from [ChatMessage] to a JS-friendly map before each call.
class MessageBridgeCommands {
  final ChatBridgeController _host;

  MessageBridgeCommands(this._host);

  /// Names the stage the running generation is actually in, so the typing
  /// bubble stops claiming the model is writing while the prompt is still
  /// being assembled. The page keeps the last label and cross-fades to the
  /// new one; an empty string restores the default "Generating…" text.
  Future<void> setGenerationPhase(String label) {
    return _host.callJs('setGenerationPhase', label);
  }

  Future<void> setMessages(
    List<ChatMessage> messages, {
    int visibleStartIndex = 0,
    bool preserveScroll = false,
  }) async {
    _host.clearCachedTriggeredRegexes();
    final List<Map<String, dynamic>> mapped = [];
    for (int i = 0; i < messages.length; i++) {
      final map = ChatMessageMapper.toMap(
        messages[i],
        _host.mapperContext,
        isLast: i == messages.length - 1,
        messageIndex: visibleStartIndex + i,
        displayRegexes: _host.displayRegexes,
        character: _host.regexCharacter,
        persona: _host.regexPersona,
        sessionVars: _host.regexSessionVars,
        globalVars: _host.regexGlobalVars,
      );
      _resolveMappedFileUrls(map);
      _host.cacheMappedTriggeredRegexes(map);
      mapped.add(map);
    }
    final resolved = await Future.wait(
      mapped.map((m) => _host.resolveImgResults(m['text'] as String)),
    );
    for (int i = 0; i < mapped.length; i++) {
      mapped[i]['text'] = resolved[i];
    }
    // Prepend the session origin ("Created on" / "Branched on") marker only
    // when the real first message is in this batch (top of the chat). During
    // scrollback windowing (visibleStartIndex > 0) the top is not shown, so the
    // marker would otherwise float above an unrelated message. Inserted after
    // the image-resolve pass above so the synthetic (text-less) entry is not
    // fed through resolveImgResults.
    final origin = _host.chatOrigin;
    // Nothing left to head: an emptied chat gets no origin marker, the same
    // rule the page applies when the last message under one is deleted
    // (`_pruneOrphanSeparators` retires `__date_origin` once no real message
    // remains).
    if (visibleStartIndex == 0 && origin != null && mapped.isNotEmpty) {
      mapped.insert(0, {...origin, '__separator': true});
    }
    final json = jsonEncode(mapped);
    if (preserveScroll) {
      // Pass the preserve-scroll flag through as a second JS argument so the
      // bridge anchors the current reading position instead of re-pinning to
      // the bottom on this batch replace.
      return _host.evalJs(
        'window.bridge?.setMessages(${_host.escapeJsonStr(json)}, true)',
      );
    }
    return _host.callJs('setMessages', json);
  }

  Future<void> appendMessage(ChatMessage message) async {
    final map = ChatMessageMapper.toMap(
      message,
      _host.mapperContext,
      displayRegexes: _host.displayRegexes,
      character: _host.regexCharacter,
      persona: _host.regexPersona,
      sessionVars: _host.regexSessionVars,
      globalVars: _host.regexGlobalVars,
    );
    _resolveMappedFileUrls(map);
    _host.cacheMappedTriggeredRegexes(map);
    map['text'] = await _host.resolveImgResults(map['text'] as String);
    final json = jsonEncode(map);
    return _host.callJs('appendMessage', json);
  }

  Future<void> appendMessages(
    List<ChatMessage> messages, {
    int startIndex = 0,
  }) async {
    final List<Map<String, dynamic>> mapped = [];
    for (int i = 0; i < messages.length; i++) {
      final map = ChatMessageMapper.toMap(
        messages[i],
        _host.mapperContext,
        isLast: i == messages.length - 1,
        messageIndex: startIndex + i,
        displayRegexes: _host.displayRegexes,
        character: _host.regexCharacter,
        persona: _host.regexPersona,
        sessionVars: _host.regexSessionVars,
        globalVars: _host.regexGlobalVars,
      );
      _resolveMappedFileUrls(map);
      _host.cacheMappedTriggeredRegexes(map);
      mapped.add(map);
    }
    final resolved = await Future.wait(
      mapped.map((m) => _host.resolveImgResults(m['text'] as String)),
    );
    for (int i = 0; i < mapped.length; i++) {
      mapped[i]['text'] = resolved[i];
    }
    final json = jsonEncode(mapped);
    return _host.callJs('appendMessages', json);
  }

  Future<void> prependMessages(
    List<ChatMessage> messages, {
    int visibleStartIndex = 0,
  }) async {
    final List<Map<String, dynamic>> mapped = [];
    for (int i = 0; i < messages.length; i++) {
      final map = ChatMessageMapper.toMap(
        messages[i],
        _host.mapperContext,
        messageIndex: visibleStartIndex + i,
        displayRegexes: _host.displayRegexes,
        character: _host.regexCharacter,
        persona: _host.regexPersona,
        sessionVars: _host.regexSessionVars,
        globalVars: _host.regexGlobalVars,
      );
      _resolveMappedFileUrls(map);
      _host.cacheMappedTriggeredRegexes(map);
      mapped.add(map);
    }
    final resolved = await Future.wait(
      mapped.map((m) => _host.resolveImgResults(m['text'] as String)),
    );
    for (int i = 0; i < mapped.length; i++) {
      mapped[i]['text'] = resolved[i];
    }
    final json = jsonEncode(mapped);
    return _host.callJs('prependMessages', json);
  }

  Future<void> updateMessage(
    ChatMessage message, {
    bool isStreamingUpdate = false,
    bool isLast = false,
  }) async {
    final map = ChatMessageMapper.toMap(
      message,
      _host.mapperContext,
      isStreamingUpdate: isStreamingUpdate,
      isLast: isLast,
      displayRegexes: _host.displayRegexes,
      character: _host.regexCharacter,
      persona: _host.regexPersona,
      sessionVars: _host.regexSessionVars,
      globalVars: _host.regexGlobalVars,
    );
    _resolveMappedFileUrls(map);
    _host.cacheMappedTriggeredRegexes(map);
    map['text'] = await _host.resolveImgResults(map['text'] as String);
    final json = jsonEncode(map);
    return _host.callJs('updateMessage', json);
  }

  Future<void> updateMessageContent(
    String messageId,
    String text,
    bool isUser,
  ) async {
    final resolved = await _host.resolveImgResults(text);
    final json = jsonEncode({
      'id': messageId,
      'text': resolved,
      'isUser': isUser,
    });
    return _host.callJs('updateMessage', json);
  }

  Future<void> removeMessage(String messageId) {
    _host.removeCachedTriggeredRegexes(messageId);
    return _host.callJs('removeMessage', messageId);
  }

  void _resolveMappedFileUrls(Map<String, dynamic> map) {
    final paths = map['imagePaths'];
    if (paths is List) {
      // A path the WebView cannot reach (the file is gone, or it lives outside
      // the served root) is dropped rather than rendered as a broken tile.
      final resolved = <String>[
        for (final path in paths.whereType<String>())
          ?_host.resolveLocalFileUrl(path),
      ];
      if (resolved.isEmpty) {
        map.remove('imagePath');
        map.remove('imagePaths');
        map.remove('imageHidden');
      } else {
        map['imagePaths'] = resolved;
        map['imagePath'] = resolved.first;
      }
      return;
    }
    final imagePath = map['imagePath'];
    if (imagePath is String) {
      final resolved = _host.resolveLocalFileUrl(imagePath);
      if (resolved == null) {
        map.remove('imagePath');
        map.remove('imageHidden');
      } else {
        map['imagePath'] = resolved;
      }
    }
  }

  Future<void> setLastMessage(String? messageId) {
    if (messageId != null) {
      return _host.evalJs(
        'window.bridge?.setLastMessage("${_host.escape(messageId)}")',
      );
    } else {
      return _host.evalJs('window.bridge?.setLastMessage(null)');
    }
  }

  /// Wipes the message list.
  ///
  /// [keepPlaceholder] is false when the *chat* is being replaced rather than
  /// re-rendered: the page parks the typing bubble across a `clearAll` +
  /// `setMessages` pair, and a session switch must not hand it to the chat
  /// being opened — nothing is generating there.
  Future<void> clearAll({bool keepPlaceholder = true}) {
    _host.clearCachedTriggeredRegexes();
    return _host.evalJs('window.bridge?.clearAll($keepPlaceholder)');
  }

  Future<void> scrollToBottom({bool smooth = false}) {
    final behavior = smooth ? "'smooth'" : "'auto'";
    return _host.evalJs('window.bridge?.scrollToBottom($behavior)');
  }

  Future<void> requestScrollToBottomOnAppend() {
    return _host.evalJs('window.bridge?.requestScrollToBottomOnAppend()');
  }

  Future<void> scrollToMessage(String messageId, {bool highlight = false}) {
    return _host.evalJs(
      'window.bridge?.scrollToMessage("${_host.escape(messageId)}", $highlight)',
    );
  }

  /// Re-shows the chat header and re-baselines the JS hide-on-scroll tracker.
  /// Call on every chat open / session switch: the WebView is kept alive across
  /// chats, so without this the tracker carries the previous chat's hidden
  /// state and scroll baseline into the new one. JS answers with an
  /// `onHeaderScroll(false)` callback, which is what actually moves the Flutter
  /// header — JS stays the single source of truth for that state.
  Future<void> showHeader() => _host.evalJs('window.bridge?.showHeader()');
}
