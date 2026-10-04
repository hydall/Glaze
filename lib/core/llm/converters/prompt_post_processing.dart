/// SillyTavern-compatible prompt post-processing.
///
/// A port of `postProcessPrompt` / `mergeMessages` from SillyTavern's
/// `src/prompt-converters.js`. The transformation runs on the finished,
/// OpenAI-shaped message array — after the prompt is built, before the
/// protocol converter reshapes it — so every provider sees the same normalized
/// conversation. It is an **API-connection** setting: which shape a request
/// must have is a property of the endpoint, not of the prompt preset.
///
/// The modes, in ST's own terms:
///
/// | Mode           | What it does                                                     |
/// |----------------|------------------------------------------------------------------|
/// | `none`         | Nothing. Messages go out exactly as built.                       |
/// | `merge`        | Squashes consecutive same-role messages into one.                |
/// | `semi`         | `merge` + every system message after the first becomes `user`.   |
/// | `strict`       | `semi` + a filler user turn so the prompt always starts on user. |
/// | `single`       | Collapses the whole conversation into one `user` message.        |
/// | `*_tools`      | Same, but tool calls / tool results survive instead of being     |
/// |                | stripped and relabelled as `user`.                               |
///
/// Every mode is idempotent: re-running it on its own output is a no-op, so a
/// request that passes through the pipeline twice is not damaged.
///
/// **Deviations from ST.** ST attaches a `name` to prompt messages (group
/// chats, example dialogue) and uses it to prefix content with `Name: ` before
/// merging. Glaze never sets `name` on API messages, so those branches are
/// inert in practice — they are ported anyway so a caller that does set one
/// (or passes [charName] / [userName]) gets ST's behaviour. ST's group-name
/// detection has no Glaze equivalent and is not ported.
library;

/// Filler user turn inserted by the strict modes when a prompt would otherwise
/// open on a non-user role. Mirrors ST's `promptPlaceholder` config default.
const String promptPostProcessingPlaceholder = "Let's get started.";

/// Content part types that survive flattening as opaque objects.
const Set<String> _nonTextPartTypes = {'image_url', 'video_url', 'audio_url'};

/// The post-processing modes, matching SillyTavern's `PROMPT_PROCESSING_TYPE`
/// values so presets and prompts stay portable between the two apps.
class PromptPostProcessing {
  const PromptPostProcessing._();

  static const String none = 'none';
  static const String mergeTools = 'merge_tools';
  static const String semiTools = 'semi_tools';
  static const String strictTools = 'strict_tools';
  static const String merge = 'merge';
  static const String semi = 'semi';
  static const String strict = 'strict';
  static const String single = 'single';

  /// Every mode the engine understands, including both halves of each pair.
  static const List<String> all = [
    none,
    mergeTools,
    semiTools,
    strictTools,
    merge,
    semi,
    strict,
    single,
  ];

  /// The families the settings UI offers, in selector order.
  ///
  /// ST splits its selector into "With Tools" / "No Tools" groups. Glaze
  /// sends no tool definitions today, so both halves of every pair produce
  /// byte-identical output and showing them would be three redundant rows.
  /// The picker offers the family and stores [withTools]; the no-tools halves
  /// stay reachable for values that arrive from ST or an older config.
  static const List<String> uiModes = [none, merge, semi, strict, single];

  /// Modes that keep `tool_calls` / `tool_call_id` and the `tool` role.
  static const Set<String> toolModes = {mergeTools, semiTools, strictTools};

  /// The tool-preserving half of a family. Picking a mode in the UI resolves
  /// through here, so a prompt that starts carrying tool traffic keeps it
  /// instead of silently losing every call the day tools are switched on.
  /// [single] has no pair — it collapses tool messages along with the rest.
  static String withTools(String mode) => switch (baseOf(mode)) {
    merge => mergeTools,
    semi => semiTools,
    strict => strictTools,
    final base => base,
  };

  /// The family a mode belongs to — `merge_tools` and `merge` both report
  /// [merge]. Labels and the picker's checkmark key off this, so a config
  /// imported from ST shows up under the row it actually corresponds to.
  static String baseOf(String mode) => switch (normalize(mode)) {
    mergeTools => merge,
    semiTools => semi,
    strictTools => strict,
    final normalized => normalized,
  };

  static bool isValid(String value) => all.contains(value);

  /// Accepts the values ST writes: `''` for "no processing" and the retired
  /// `'claude'` alias for [merge]. Anything unrecognised degrades to [none]
  /// rather than silently reshaping the prompt.
  static String normalize(String? value) {
    if (value == null || value.isEmpty) return none;
    if (value == 'claude') return merge;
    return isValid(value) ? value : none;
  }
}

/// Applies the [type] post-processing pass to [messages].
///
/// [messages] is never mutated — every returned message is a fresh map, so the
/// caller's copy stays intact for cache-breakpoint hashing and diagnostics.
List<Map<String, dynamic>> postProcessPrompt(
  List<Map<String, dynamic>> messages,
  String type, {
  String? charName,
  String? userName,
}) {
  switch (PromptPostProcessing.normalize(type)) {
    case PromptPostProcessing.merge:
      return _mergeMessages(
        messages,
        strict: false,
        placeholders: false,
        single: false,
        tools: false,
        charName: charName,
        userName: userName,
      );
    case PromptPostProcessing.mergeTools:
      return _mergeMessages(
        messages,
        strict: false,
        placeholders: false,
        single: false,
        tools: true,
        charName: charName,
        userName: userName,
      );
    case PromptPostProcessing.semi:
      return _mergeMessages(
        messages,
        strict: true,
        placeholders: false,
        single: false,
        tools: false,
        charName: charName,
        userName: userName,
      );
    case PromptPostProcessing.semiTools:
      return _mergeMessages(
        messages,
        strict: true,
        placeholders: false,
        single: false,
        tools: true,
        charName: charName,
        userName: userName,
      );
    case PromptPostProcessing.strict:
      return _mergeMessages(
        messages,
        strict: true,
        placeholders: true,
        single: false,
        tools: false,
        charName: charName,
        userName: userName,
      );
    case PromptPostProcessing.strictTools:
      return _mergeMessages(
        messages,
        strict: true,
        placeholders: true,
        single: false,
        tools: true,
        charName: charName,
        userName: userName,
      );
    case PromptPostProcessing.single:
      return _mergeMessages(
        messages,
        strict: true,
        placeholders: false,
        single: true,
        tools: false,
        charName: charName,
        userName: userName,
      );
    default:
      return messages;
  }
}

/// The single transformation every mode is a parameterisation of.
///
/// - [strict] — relabel every system message after the first as `user`, then
///   re-squash. This is what makes the conversation alternate.
/// - [placeholders] — with [strict], insert [promptPostProcessingPlaceholder]
///   so the first non-system turn is a user turn.
/// - [single] — force every role to `user`, which collapses the prompt into
///   one message once consecutive roles are squashed.
/// - [tools] — keep tool traffic. When false, `tool` messages become `user`
///   messages and `tool_calls` / `tool_call_id` are dropped.
List<Map<String, dynamic>> _mergeMessages(
  List<Map<String, dynamic>> messages, {
  required bool strict,
  required bool placeholders,
  required bool single,
  required bool tools,
  String? charName,
  String? userName,
}) {
  // Multimodal parts can't be concatenated as text, so they are swapped for
  // opaque tokens, merged as text, and restored afterwards — ST's own trick.
  final parts = <String, dynamic>{};
  var partSeq = 0;

  final flattened = <Map<String, dynamic>>[];
  for (final source in messages) {
    final message = Map<String, dynamic>.from(source);
    final role = (message['role'] as String?) ?? 'user';
    final name = message['name'] as String?;

    final content = message['content'];
    var text = content is List
        ? content
              .map((part) {
                if (part is! Map) return '';
                if (part['type'] == 'text') {
                  return (part['text'] as String?) ?? '';
                }
                if (_nonTextPartTypes.contains(part['type'])) {
                  // NUL cannot occur inside JSON string content, so the
                  // token can never collide with real prompt text.
                  final token = '\u0000glaze-part-${partSeq++}\u0000';
                  parts[token] = part;
                  return token;
                }
                return '';
              })
              .join('\n\n')
        : content is String
        ? content
        : (content?.toString() ?? '');

    // Names ride along inside the text once roles start merging.
    if (role == 'system' && name == 'example_assistant') {
      text = _prefixName(text, charName);
    } else if (role == 'system' && name == 'example_user') {
      text = _prefixName(text, userName);
    } else if (role != 'system' && name != null && name.isNotEmpty) {
      text = _prefixName(text, name);
    }

    var nextRole = role;
    if (role == 'tool' && !tools) nextRole = 'user';
    if (single) {
      // Everything becomes one user turn, so speaker labels are the only thing
      // left telling the model who said what.
      if (role == 'assistant') text = _prefixName(text, charName);
      if (role == 'user') text = _prefixName(text, userName);
      nextRole = 'user';
    }

    message['role'] = nextRole;
    message['content'] = text;
    message.remove('name');
    if (!tools) {
      message.remove('tool_calls');
      message.remove('tool_call_id');
    }
    flattened.add(message);
  }

  // Squash consecutive same-role messages. Empty messages never absorb into
  // their predecessor, and tool results always stand alone — a merged tool
  // message would lose its `tool_call_id` pairing.
  final merged = <Map<String, dynamic>>[];
  for (final message in flattened) {
    final text = message['content'] as String;
    final previous = merged.isEmpty ? null : merged.last;
    if (previous != null &&
        previous['role'] == message['role'] &&
        message['role'] != 'tool' &&
        text.isNotEmpty) {
      previous['content'] = '${previous['content']}\n\n$text';
    } else {
      merged.add(message);
    }
  }

  // Providers reject an empty conversation outright.
  if (merged.isEmpty) {
    merged.add({'role': 'user', 'content': promptPostProcessingPlaceholder});
  }

  if (parts.isNotEmpty) _restoreParts(merged, parts);

  if (strict) {
    for (var i = 1; i < merged.length; i++) {
      if (merged[i]['role'] == 'system') merged[i]['role'] = 'user';
    }
    if (placeholders) {
      final first = merged.first['role'];
      if (first == 'system' &&
          (merged.length == 1 || merged[1]['role'] != 'user')) {
        merged.insert(1, {
          'role': 'user',
          'content': promptPostProcessingPlaceholder,
        });
      } else if (first != 'system' && first != 'user') {
        merged.insert(0, {
          'role': 'user',
          'content': promptPostProcessingPlaceholder,
        });
      }
    }
    // Relabelling systems as user creates new same-role runs; squash again.
    return _mergeMessages(
      merged,
      strict: false,
      placeholders: placeholders,
      single: false,
      tools: tools,
      charName: charName,
      userName: userName,
    );
  }

  return merged;
}

/// Rebuilds multimodal content: splits the merged text back on the separator
/// and swaps every token for the part it stood in for.
void _restoreParts(
  List<Map<String, dynamic>> messages,
  Map<String, dynamic> parts,
) {
  for (final message in messages) {
    final content = message['content'];
    if (content is! String) continue;
    if (!parts.keys.any(content.contains)) continue;

    final rebuilt = <dynamic>[];
    for (final chunk in content.split('\n\n')) {
      final part = parts[chunk];
      if (part != null) {
        rebuilt.add(part);
        continue;
      }
      final last = rebuilt.isEmpty ? null : rebuilt.last;
      if (last is Map && last['type'] == 'text') {
        last['text'] = '${last['text']}\n\n$chunk';
      } else {
        rebuilt.add({'type': 'text', 'text': chunk});
      }
    }
    message['content'] = rebuilt;
  }
}

/// Prefixes `name: ` unless [text] already carries it.
String _prefixName(String text, String? name) {
  if (name == null || name.isEmpty) return text;
  if (text.startsWith('$name: ')) return text;
  return '$name: $text';
}
