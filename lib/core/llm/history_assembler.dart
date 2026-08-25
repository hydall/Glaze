import '../models/chat_message.dart';
import 'macro_engine.dart';

class HistoryAssembler {
  final MacroContext macroCtx;

  HistoryAssembler(this.macroCtx);

  List<PromptMessage> assemble(List<ChatMessage> history) {
    if (history.isEmpty) return [];

    final messages = <PromptMessage>[];

    for (int i = 0; i < history.length; i++) {
      final msg = history[i];
      if (msg.isHidden || msg.isTyping) continue;
      final macroResult = replaceMacros(msg.content, macroCtx);
      final normalized = _normalizeUnderscoreEmphasis(macroResult.text);
      messages.add(
        PromptMessage(
          role: msg.role,
          content: _withGameTime(normalized, msg),
          reasoningContent: msg.reasoning,
          isHistory: true,
          sourceMessageId: msg.id,
          // The eye toggle on an attachment hides it from the model only —
          // the bubble keeps rendering it. Default is visible.
          imagePath: msg.imageHidden ? null : msg.imagePath,
        ),
      );
    }

    return messages;
  }

  /// The in-game clock travels with the chat history itself: every message
  /// stamped by the ledger carries its full game time, so the model sees the
  /// whole progression of the clock instead of a single current timestamp.
  String _withGameTime(String content, ChatMessage msg) {
    final time = msg.time?.trim();
    if (time == null || time.isEmpty) return content;
    if (content.isEmpty) return '[$time]';
    return '[$time]\n$content';
  }
}

List<PromptMessage> interleaveDepthWithHistory(
  List<PromptMessage> historyMsgs,
  List<PromptMessage> depthBlocks,
) {
  if (depthBlocks.isEmpty) return historyMsgs;

  final result = <PromptMessage>[];

  final deepBlocks = depthBlocks.where(
    (b) => (b.depth ?? 0) > historyMsgs.length,
  );
  result.addAll(deepBlocks);

  for (int i = 0; i <= historyMsgs.length; i++) {
    final currentDepth = historyMsgs.length - i;
    final blocksAtDepth = depthBlocks.where(
      (b) => (b.depth ?? 0) == currentDepth,
    );
    result.addAll(blocksAtDepth);

    if (i < historyMsgs.length) {
      result.add(historyMsgs[i]);
    }
  }

  return result;
}

class PromptMessage {
  final String role;
  final String content;
  final String? blockId;
  final int? depth;
  final bool isHistory;
  final bool isDepth;
  final bool isLorebook;
  final bool isSummary;
  final String? blockName;
  final String? sourceMessageId;
  final String? reasoningContent;
  final String? imagePath;
  final bool sendEmptyBlock;

  const PromptMessage({
    required this.role,
    required this.content,
    this.blockId,
    this.depth,
    this.isHistory = false,
    this.isDepth = false,
    this.isLorebook = false,
    this.isSummary = false,
    this.blockName,
    this.sourceMessageId,
    this.reasoningContent,
    this.imagePath,
    this.sendEmptyBlock = false,
  });

  bool get hasImage => imagePath?.isNotEmpty == true;

  Map<String, dynamic> toApiMap() {
    if (!hasImage) return {'role': role, 'content': content};
    return {
      'role': role,
      'content': [
        if (content.isNotEmpty) {'type': 'text', 'text': content},
        {
          'type': 'image_url',
          'image_url': {'url': imagePath},
        },
      ],
    };
  }

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    'blockId': blockId,
    'depth': depth,
    'isHistory': isHistory,
    'isDepth': isDepth,
    'isLorebook': isLorebook,
    'isSummary': isSummary,
    'blockName': blockName,
    'sourceMessageId': sourceMessageId,
    'reasoningContent': reasoningContent,
    'imagePath': imagePath,
    'sendEmptyBlock': sendEmptyBlock,
  };

  factory PromptMessage.fromJson(Map<String, dynamic> json) => PromptMessage(
    role: json['role'] as String,
    content: json['content'] as String,
    blockId: json['blockId'] as String?,
    depth: json['depth'] as int?,
    isHistory: json['isHistory'] as bool? ?? false,
    isDepth: json['isDepth'] as bool? ?? false,
    isLorebook: json['isLorebook'] as bool? ?? false,
    isSummary: json['isSummary'] as bool? ?? false,
    blockName: json['blockName'] as String?,
    sourceMessageId: json['sourceMessageId'] as String?,
    reasoningContent: json['reasoningContent'] as String?,
    imagePath: json['imagePath'] as String?,
    sendEmptyBlock: json['sendEmptyBlock'] as bool? ?? false,
  );
}

List<Map<String, dynamic>> buildApiMessages(
  List<PromptMessage> messages, {
  int reasoningHistoryCount = 0,
}) {
  final included = messages
      .where(
        (message) =>
            message.content.trim().isNotEmpty ||
            message.hasImage ||
            message.sendEmptyBlock,
      )
      .toList();
  final result = included.map((message) => message.toApiMap()).toList();
  if (reasoningHistoryCount == 0 || reasoningHistoryCount < -1) return result;

  final includeAll = reasoningHistoryCount == -1;
  var remaining = reasoningHistoryCount;
  for (
    var i = included.length - 1;
    i >= 0 && (includeAll || remaining > 0);
    i--
  ) {
    final message = included[i];
    if (message.role != 'assistant') continue;
    final reasoning = message.reasoningContent?.trim();
    if (reasoning?.isNotEmpty == true) {
      result[i]['reasoning_content'] = reasoning;
      if (!includeAll) remaining--;
    }
  }
  return result;
}

String _normalizeUnderscoreEmphasis(String text) {
  var result = text;
  result = result.replaceAllMapped(
    RegExp(r'(?<!\w)__(?!\s)(.+?)(?<!\s)__(?!\w)'),
    (m) => '**${m[1]}**',
  );
  result = result.replaceAllMapped(
    RegExp(r'(?<!\w|_)_(?!\s)(.+?)(?<!\s)_(?!\w|_)'),
    (m) => '*${m[1]}*',
  );
  return result;
}
