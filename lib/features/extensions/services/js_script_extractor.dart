/// Parses LLM output into executable JavaScript for [BlockType.jsRunner].
class JsScriptExtractor {
  JsScriptExtractor._();

  static final _fencedJs = RegExp(
    r'```(?:javascript|js)\s*\r?\n([\s\S]*?)```',
    caseSensitive: false,
  );

  static final _fencedGeneric = RegExp(
    r'```[^\r\n]*\r?\n([\s\S]*?)```',
  );

  /// Returns executable JS from markdown fences or the trimmed raw reply.
  static String? extractFromLlmResponse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    for (final pattern in [_fencedJs, _fencedGeneric]) {
      final match = pattern.firstMatch(trimmed);
      final code = match?.group(1)?.trim();
      if (code != null && code.isNotEmpty) return code;
    }

    return trimmed;
  }

  static String escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  static bool _looksLikeHtml(String text) {
    return RegExp(r'^<[a-z][\s\S]*>', caseSensitive: false).hasMatch(text.trim());
  }

  /// Panel HTML: collapsible script + execution result.
  static String formatPanelContent({
    required String script,
    required String result,
  }) {
    final escapedScript = escapeHtml(script);
    final body = _looksLikeHtml(result) ? result : escapeHtml(result);
    return '''
<details class="ext-block-js-source">
<summary>Сгенерированный скрипт</summary>
<pre><code>$escapedScript</code></pre>
</details>
<div class="ext-block-js-result">$body</div>''';
  }
}
