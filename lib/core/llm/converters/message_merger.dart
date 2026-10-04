/// Pure helpers for "merge into one block" transformations.
///
/// Consecutive **non-assistant** messages get squashed into a single message
/// with `mergeRole` as the resulting role. Assistant messages act as fences
/// and break the merge run.
///
/// No transport calls this today. Prompt reshaping is an API-connection
/// setting now — see `prompt_post_processing.dart`, which ports SillyTavern's
/// modes and runs on the finished message array — and the Gemini transport
/// deliberately does *not* pre-merge: it mirrors ST, where only the leading
/// run of genuine `system` messages is lifted into `systemInstruction` and
/// consecutive same-role turns are squashed inside `contents`. Pre-merging
/// relabels a leading user turn as `system`, which would push it into
/// `systemInstruction` too.
///
/// Kept because it is a pure, tested helper: reach for it via
/// `convertGoogleMessagesMerged` if a caller ever wants the collapse-first
/// shape back.
///
/// This function is idempotent: re-running it produces the same result.
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
