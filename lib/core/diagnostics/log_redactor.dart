/// Masks credentials in a log line before it reaches disk.
///
/// Logs leave the device whenever a user shares them, and the code that writes
/// them was never reviewed with that in mind: a request error can echo an
/// `Authorization` header, a provider error body quotes the key it rejected.
/// Everything that looks like a secret is cut down to its first few characters
/// so a report still shows *which* key was in play without handing it over.
abstract final class LogRedactor {
  static final List<(RegExp, String Function(Match))> _rules = [
    // `Authorization: Bearer xxx`, `Bearer xxx` anywhere.
    (
      RegExp(r'(Bearer\s+)([A-Za-z0-9._~+/=-]{6,})', caseSensitive: false),
      (m) => '${m[1]}${_mask(m[2]!)}',
    ),
    // OpenAI / Anthropic / OpenRouter style keys: sk-..., sk-ant-..., sk-or-...
    (RegExp(r'\b(sk-[A-Za-z0-9_-]{8,})'), (m) => _mask(m[1]!)),
    // Google API keys.
    (RegExp(r'\b(AIza[0-9A-Za-z_-]{20,})'), (m) => _mask(m[1]!)),
    // `"api_key": "x"`, `token=x`, `x-api-key: x`, `?key=x` and friends.
    // `Authorization: Bearer x` is left to the Bearer rule above.
    (
      RegExp(
        r'''((?:api[_-]?key|x-api-key|access[_-]?token|refresh[_-]?token|token|secret|password|authorization|key)["']?\s*[:=]\s*["']?)(?!Bearer\s)([^\s"',&;}]{6,})''',
        caseSensitive: false,
      ),
      (m) => '${m[1]}${_mask(m[2]!)}',
    ),
  ];

  static String redact(String input) {
    var out = input;
    for (final (pattern, replace) in _rules) {
      out = out.replaceAllMapped(pattern, replace);
    }
    return out;
  }

  static String _mask(String secret) {
    // Already masked by an earlier rule (`Authorization: Bearer sk-…`).
    if (secret.contains('***')) return secret;
    final keep = secret.length > 12 ? 4 : 2;
    return '${secret.substring(0, keep)}***';
  }
}
