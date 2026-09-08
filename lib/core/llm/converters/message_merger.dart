/// Pure helpers for "merge into one block" transformations.
///
/// Mirrors the behaviour of `preset.mergePrompts` in `prompt_builder.dart`:
/// consecutive **non-assistant** messages get squashed into a single message
/// with `mergeRole` as the resulting role. Assistant messages act as fences
/// and break the merge run.
///
/// Used in two places:
/// 1. **OpenAI / Custom transports**: not called directly here — the preset
///    flag `mergePrompts` drives the merge at prompt build time. The flag is
///    a per-preset toggle the user controls in the preset editor.
/// 2. **Gemini transport**: called unconditionally on already-built messages
///    before converting to Gemini's `contents`/`systemInstruction` shape.
///    Gemini doesn't accept multiple system blocks and is strict about
///    alternating roles, so collapsing non-assistant chrome is always safe.
///
/// This function is idempotent: re-running it produces the same result, so
/// the Gemini transport can safely apply it on top of an already-merged
/// preset output.
library;

const String _kAssistant = 'assistant';
const String _kModel = 'model';

/// Squashes runs of consecutive non-assistant messages into a single message
/// with the given [mergeRole].
///
/// - Messages are expected in OpenAI shape: `{role, content}`. Other fields
///   (`name`, `tool_call_id`, etc.) are preserved on the FIRST message of
///   each run; the merged content is `content1 + '\n\n' + content2 + ...`.
/// - `content` may be a `String` or a `List` of content parts (OpenAI
///   multimodal). When merging a mix, content parts get concatenated as a
///   `List` so vision attachments survive the merge.
/// - Assistant messages pass through untouched. Both `'assistant'` and
///   `'model'` (Gemini convention) are treated as the assistant fence.
List<Map<String, dynamic>> mergeNonAssistant(
  List<Map<String, dynamic>> messages, {
  String mergeRole = 'system',
}) {
  if (messages.isEmpty) return const [];

  final out = <Map<String, dynamic>>[];
  Map<String, dynamic>? pending;

  void flush() {
    if (pending != null) {
      out.add(pending!);
      pending = null;
    }
  }

  for (final msg in messages) {
    final role = (msg['role'] as String?) ?? 'user';
    final isAssistant = role == _kAssistant || role == _kModel;

    if (isAssistant) {
      flush();
      out.add(Map<String, dynamic>.from(msg));
      continue;
    }

    if (pending == null) {
      pending = Map<String, dynamic>.from(msg);
      pending!['role'] = mergeRole;
      continue;
    }

    pending!['content'] = _mergeContent(pending!['content'], msg['content']);
  }
  flush();

  return out;
}

/// Concatenates two `content` values (String or List of parts) preserving
/// multimodal parts.
dynamic _mergeContent(dynamic a, dynamic b) {
  if (a is String && b is String) {
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    return '$a\n\n$b';
  }
  // Promote both to part lists.
  final aParts = _toParts(a);
  final bParts = _toParts(b);
  if (aParts.isEmpty) return b;
  if (bParts.isEmpty) return a;
  // If the seam between aParts.last and bParts.first is both text, merge
  // them with the standard `\n\n` separator so the merged output reads
  // like the String case.
  final merged = [...aParts];
  final firstB = bParts.first;
  if (merged.last is Map &&
      (merged.last as Map)['type'] == 'text' &&
      firstB is Map &&
      firstB['type'] == 'text') {
    final lastText = ((merged.last as Map)['text'] as String?) ?? '';
    final firstText = (firstB['text'] as String?) ?? '';
    merged[merged.length - 1] = {
      'type': 'text',
      'text': lastText.isEmpty
          ? firstText
          : (firstText.isEmpty ? lastText : '$lastText\n\n$firstText'),
    };
    merged.addAll(bParts.skip(1));
  } else {
    merged.addAll(bParts);
  }
  return merged;
}

List<dynamic> _toParts(dynamic content) {
  if (content == null) return const [];
  if (content is String) {
    if (content.isEmpty) return const [];
    return [
      {'type': 'text', 'text': content},
    ];
  }
  if (content is List) return content;
  return const [];
}
