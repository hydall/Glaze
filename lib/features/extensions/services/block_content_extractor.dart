import '../models/block_config.dart';

/// Opening tag name from [BlockConfig.template] (e.g. `loomledger`), or [BlockConfig.name].
String blockTagName(BlockConfig blockConfig, String resolvedTemplate) {
  final fromTemplate =
      RegExp(r'<([a-zA-Z][\w-]*)').firstMatch(resolvedTemplate)?.group(1);
  if (fromTemplate != null && fromTemplate.isNotEmpty) return fromTemplate;
  return blockConfig.name.trim();
}

/// Elements that *are* the content, even with no text around them. A block
/// that draws a picture or hosts a panel is legitimately markup-only, and the
/// tag stripper below would otherwise call its whole reply empty — which is
/// exactly how an image block surfaces "LLM returned empty block" after a
/// perfectly good generation.
final _renderableElement = RegExp(
  r'<(img|picture|source|iframe|video|audio|canvas|svg|embed|object)\b',
  caseSensitive: false,
);

/// True when [content] has no visible text after stripping HTML/markdown noise.
///
/// Markup-only is not empty while it carries a renderable element: an
/// `<img>` card has nothing to read but plenty to show.
bool isBlankBlockContent(String content) {
  var text = content;
  text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');
  text = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
  text = text.replaceAll('&nbsp;', ' ');
  text = text.replaceAll(RegExp(r'\s+'), ' ');
  if (text.trim().isNotEmpty) return false;
  return !_renderableElement.hasMatch(content);
}

/// Extracts inner HTML/text from `<tag>...</tag>`. Returns null when tags are
/// missing or inner is whitespace-only (caller should fall back to raw output).
String? extractBlockInnerContent(String response, String tagName) {
  if (response.isEmpty || tagName.isEmpty) return null;
  final escaped = RegExp.escape(tagName);
  final pattern = RegExp(
    '<$escaped(\\s+[^>]*)?>([\\s\\S]*?)<\\/$escaped>',
    multiLine: true,
    caseSensitive: false,
  );
  final match = pattern.firstMatch(response);
  if (match == null) return null;
  final inner = (match.group(2) ?? '').trim();
  if (inner.isEmpty) return null;
  return inner;
}

/// Picks storable block content from a raw LLM reply.
String? resolveBlockContent({
  required String rawResponse,
  required BlockConfig blockConfig,
  required String resolvedTemplate,
}) {
  final trimmed = rawResponse.trim();
  if (trimmed.isEmpty) return null;

  final useTags = resolvedTemplate.trim().isNotEmpty;
  if (useTags) {
    final tag = blockTagName(blockConfig, resolvedTemplate);
    final inner = extractBlockInnerContent(trimmed, tag);
    if (inner != null && !isBlankBlockContent(inner)) return inner;
  }

  if (!isBlankBlockContent(trimmed)) return trimmed;
  return null;
}
