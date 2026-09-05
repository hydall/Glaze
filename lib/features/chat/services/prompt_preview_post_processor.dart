/// Replays the connection's prompt post-processing over the built prompt so
/// the Prompt Inspector's formatted view shows the messages that actually
/// leave the device, not the block list the builder produced.
///
/// The raw JSON view already goes through
/// `PostProcessingChatTransport.applyTo`, so without this the two halves of
/// the same tab disagree the moment a mode other than `none` is selected: the
/// JSON shows three merged messages while the cards above it still list
/// twenty separate blocks.
///
/// The pass itself is never re-implemented here — [postProcessPrompt] is the
/// single source of truth for what each mode does. Provenance is recovered by
/// running the real pass over placeholder content: every built message is
/// swapped for a unique token, so each output message's text is exactly the
/// tokens of the blocks that landed in it, joined by the merge separator.
/// Reading the tokens back gives an exact block → message mapping without a
/// second, drift-prone copy of the merge rules.
library;

import '../../../core/llm/converters/prompt_post_processing.dart';
import '../../../core/llm/history_assembler.dart';

/// One row of the formatted preview: the message as it will be sent, plus the
/// built blocks that were folded into it.
class PreviewMessage {
  /// The outgoing message. For a merged row, [PromptMessage.content] is the
  /// concatenation of every source's content and the classification flags are
  /// the union of the sources', so the section filters keep working.
  final PromptMessage message;

  /// The built blocks this row came from, in prompt order. Empty for the
  /// filler turn the strict modes insert, which corresponds to no block.
  final List<PromptMessage> sources;

  const PreviewMessage({required this.message, required this.sources});

  /// True when post-processing folded several blocks into this one message.
  bool get isMerged => sources.length > 1;

  /// Every image carried by the sources. A merge can pull several attachments
  /// into one message, so the card renders the list rather than a single path.
  List<String> get imagePaths => [
    for (final source in sources)
      for (final path in source.imagePaths)
        if (path.isNotEmpty) path,
  ];
}

/// Separator [postProcessPrompt] uses when it glues two messages together.
const String _mergeSeparator = '\n\n';

/// Stand-in content for one built message. NUL cannot appear in prompt text,
/// so a token never collides with real content, and it carries no newline, so
/// it always survives the merge as a chunk of its own.
const String _tokenPrefix = '\u0000glaze-preview-';
const String _tokenSuffix = '\u0000';

/// Applies [mode] to [messages] and returns the resulting rows.
///
/// With [PromptPostProcessing.none] every message passes through untouched,
/// one row each. Any other mode reproduces the request faithfully, so empty
/// blocks are dropped unless their per-block opt-in keeps them.
List<PreviewMessage> buildPreviewMessages(
  List<PromptMessage> messages,
  String mode, {
  String? charName,
  String? userName,
}) {
  final normalized = PromptPostProcessing.normalize(mode);
  if (normalized == PromptPostProcessing.none) {
    return [
      for (final message in messages)
        PreviewMessage(message: message, sources: [message]),
    ];
  }

  final included = messages
      .where(
        (message) =>
            message.content.trim().isNotEmpty ||
            message.hasImage ||
            message.sendEmptyBlock,
      )
      .toList();

  final tagged = [
    for (var i = 0; i < included.length; i++)
      {'role': included[i].role, 'content': '$_tokenPrefix$i$_tokenSuffix'},
  ];

  final processed = postProcessPrompt(
    tagged,
    normalized,
    charName: charName,
    userName: userName,
  );

  final rows = <PreviewMessage>[];
  for (final message in processed) {
    final role = (message['role'] as String?) ?? 'user';
    final content = message['content'];
    final text = content is String ? content : '';

    final sources = <PromptMessage>[];
    final chunks = <String>[];
    for (final chunk in text.split(_mergeSeparator)) {
      final index = _tokenIndex(chunk, charName: charName, userName: userName);
      if (index == null || index >= included.length) {
        // Not a token: text the pass itself introduced, i.e. the filler turn.
        chunks.add(chunk);
        continue;
      }
      final source = included[index];
      sources.add(source);
      if (source.content.isNotEmpty) {
        chunks.add(
          _displayContent(
            source,
            mode: normalized,
            charName: charName,
            userName: userName,
          ),
        );
      }
    }

    rows.add(
      PreviewMessage(
        message: _synthesize(role, chunks.join(_mergeSeparator), sources),
        sources: sources,
      ),
    );
  }
  return rows;
}

/// Parses a token back into its source index; null for anything else.
int? _tokenIndex(String chunk, {String? charName, String? userName}) {
  var token = chunk;
  for (final name in [charName, userName]) {
    if (name != null && name.isNotEmpty && token.startsWith('$name: ')) {
      token = token.substring(name.length + 2);
      break;
    }
  }
  if (!token.startsWith(_tokenPrefix) || !token.endsWith(_tokenSuffix)) {
    return null;
  }
  return int.tryParse(
    token.substring(_tokenPrefix.length, token.length - _tokenSuffix.length),
  );
}

String _displayContent(
  PromptMessage source, {
  required String mode,
  String? charName,
  String? userName,
}) {
  if (mode != PromptPostProcessing.single) return source.content;
  final name = switch (source.role) {
    'assistant' => charName,
    'user' => userName,
    _ => null,
  };
  if (name == null || name.isEmpty || source.content.startsWith('$name: ')) {
    return source.content;
  }
  return '$name: ${source.content}';
}

/// Builds the message a row displays. A single source keeps its own metadata;
/// a merge unions the flags and joins the block names, since the merged text
/// really is all of those blocks.
PromptMessage _synthesize(
  String role,
  String content,
  List<PromptMessage> sources,
) {
  if (sources.length == 1) {
    final source = sources.single;
    return PromptMessage(
      role: role,
      content: content,
      blockId: source.blockId,
      depth: source.depth,
      isHistory: source.isHistory,
      isDepth: source.isDepth,
      isLorebook: source.isLorebook,
      isSummary: source.isSummary,
      blockName: source.blockName,
      sourceMessageId: source.sourceMessageId,
      reasoningContent: source.reasoningContent,
      imagePaths: source.imagePaths,
      sendEmptyBlock: source.sendEmptyBlock,
    );
  }

  final names = <String>[];
  for (final source in sources) {
    final name = source.blockName;
    if (name != null && name.isNotEmpty && !names.contains(name)) {
      names.add(name);
    }
  }

  return PromptMessage(
    role: role,
    content: content,
    isHistory: sources.any((s) => s.isHistory),
    isDepth: sources.any((s) => s.isDepth),
    isLorebook: sources.any((s) => s.isLorebook),
    isSummary: sources.any((s) => s.isSummary),
    blockName: names.isEmpty ? null : names.join(' + '),
  );
}
