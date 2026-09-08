import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/transport/chat_transport_request.dart';
import '../../../core/llm/transport/transport_factory.dart';
import '../../../core/models/lorebook.dart';
import '../../../core/utils/id_generator.dart';
import '../../../core/utils/time_helpers.dart';
import '../../settings/api_list_provider.dart';

/// Rebuilds raw, concatenated closed-lorebook text into structured
/// [LorebookEntry]s using Glaze's **active LLM connection** — a Dart port of
/// the SillyTavern `janitor-lorebook` frontend extension's `buildWithActiveLLM`.
///
/// The capture step (see `JanitorWebViewProxy.captureGenerateAlpha`) yields the
/// concatenated bodies of the entries the platform injected; this asks the LLM
/// to split them back into discrete, keyed World Info entries.

const String _systemPrompt = '''You reconstruct a SillyTavern World Info (lorebook) from raw text.

You are given text extracted from an LLM chat prompt: one or more lorebook entries a
roleplay platform injected because their trigger keywords matched. The character card and
user persona have already been removed; what remains is lorebook entry bodies concatenated
together (often separated by blank lines). You may also be given the character card and a
catalog/world description as CONTEXT — use those ONLY to infer better keys, never output
them as entries.

Your job:
1. Split the text into discrete, self-contained World Info entries. Each coherent block
   about one topic (a person, place, faction, item, rule, lore fact) is one entry. Do NOT
   merge unrelated topics; do NOT split a single topic across entries.
2. For each entry write:
   - "content": the entry body, faithful to the source.
   - "key": array of primary trigger keywords/phrases (names, aliases, places, distinctive
     nouns), inferred from the content and the provided context.
   - "keysecondary": optional array of secondary keywords (else []).
   - "comment": a short title (the topic name).
   - "order": optional integer insertion order; default 100.
3. Output ONLY a JSON object:
   { "entries": [ { "comment": "...", "key": ["..."], "keysecondary": [], "content": "...", "order": 100 }, ... ] }
No markdown, no prose, no code fences — JSON only.''';

/// System prompt for the JS-source path: a JanitorAI "advanced" / Nine API
/// lorebook is shipped as JavaScript (e.g. `const loreEntries = [ ... ]`) rather
/// than a JSON entries array, so the model is asked to recover the entries from
/// the source instead of splitting concatenated bodies.
const String _systemPromptJs =
    '''You reconstruct a SillyTavern World Info (lorebook) from JavaScript source.

You are given the JavaScript source of a JanitorAI "advanced" / Nine API lorebook script. It
typically defines an array of lore entries (often `const loreEntries = [ ... ]`), where each
entry is an object with fields such as `keywords`/`keys`/`keysRaw`, `content`, `personality`,
`scenario`, `name`/`title`/`category`, `constant`, `priority`/`insertion_order`, and an
optional `filters.notWith` (secondary "not with" keywords). Some scripts assemble entries
with code; recover the resulting lore regardless.

You may also be given the character card and a catalog/world description as CONTEXT — use
those ONLY to infer better keys, never output them as entries.

Your job:
1. Recover every distinct lore entry the script defines. Do NOT invent entries the script
   does not contain; do NOT merge unrelated entries or split a single entry.
2. For each entry write:
   - "content": the entry body. If an entry has no `content` but has `personality` and/or
     `scenario`, combine those into the content.
   - "key": array of primary trigger keywords (from `keywords`/`keys`/`keysRaw`).
   - "keysecondary": secondary keywords (e.g. from `filters.notWith`), else [].
   - "comment": a short title (from `name`/`title`/`category`).
   - "order": optional integer insertion order (from `priority`/`insertion_order`); default 100.
3. Output ONLY a JSON object:
   { "entries": [ { "comment": "...", "key": ["..."], "keysecondary": [], "content": "...", "order": 100 }, ... ] }
No markdown, no prose, no code fences — JSON only.''';

/// System prompt for the **full-prompt** path: used when the character has at
/// least one JanitorAI "advanced" / Nine API lorebook. Such scripts inject their
/// entries INLINE inside the persona block, so the mechanical separator can't
/// isolate them — instead the whole assembled prompt is handed to the model,
/// which separates the injected lorebook entries from the base card/scenario.
const String _systemPromptFull =
    '''You reconstruct a SillyTavern World Info (lorebook) from a full assembled chat prompt.

You are given the COMPLETE system prompt of a roleplay chat. It contains the character
card / persona, the scenario, optional example dialogue, AND lorebook (World Info) entries
the platform injected because their trigger keywords matched. The injected entries are
usually discrete topical blocks (a person, place, faction, item, rule, lore fact) — often
bracketed like `[Name: ...]` — and may appear INLINE within the persona or after it.

You may also be given the character card, catalog description, scenario and greetings as
CONTEXT. Use them to tell the BASE character definition apart from the injected lorebook:
the base persona/scenario/example prose is NOT a lorebook entry, even though it appears in
the prompt.

Your job:
1. Extract ONLY the injected lorebook entries — discrete, self-contained World Info entries
   about a single topic each. Do NOT output the base character card, persona, scenario,
   example dialogue, or any system/jailbreak instructions as entries. Do NOT merge unrelated
   topics; do NOT split a single topic across entries.
2. For each entry write:
   - "content": the entry body, faithful to the source (drop stray "undefined" tokens and
     leftover wrapper tags).
   - "key": array of primary trigger keywords/phrases (names, aliases, places, distinctive
     nouns), inferred from the content and the provided context.
   - "keysecondary": optional array of secondary keywords (else []).
   - "comment": a short title (the topic name).
   - "order": optional integer insertion order; default 100.
3. Output ONLY a JSON object:
   { "entries": [ { "comment": "...", "key": ["..."], "keysecondary": [], "content": "...", "order": 100 }, ... ] }
No markdown, no prose, no code fences — JSON only.''';

/// Thrown when no usable LLM connection is configured.
class NoActiveConnectionException implements Exception {
  @override
  String toString() =>
      'No active LLM connection. Configure one in Settings → API first.';
}

/// Thrown when the build LLM call returns nothing usable. Carries the raw
/// provider output so the UI can show a debug panel and the user can see what
/// actually came back (empty content, a reasoning-only response, a content
/// filter, etc.).
class LorebookBuildException implements Exception {
  final String message;

  /// The assistant text the transport surfaced (often empty on failure).
  final String rawText;

  /// Separate reasoning/thinking stream, if the model emitted one.
  final String? reasoning;

  /// The raw provider JSON payload (the most useful field for diagnosis).
  final String? rawResponseJson;

  LorebookBuildException(
    this.message, {
    this.rawText = '',
    this.reasoning,
    this.rawResponseJson,
  });

  @override
  String toString() => message;
}

/// Assembles the exact chat messages sent to the build LLM: a `system` prompt
/// plus a single `user` message bundling every selected context block followed
/// by the raw lorebook text. Exposed so the UI can PREVIEW the prompt without
/// spending a call. Port of JAR `extract.js` `buildExtractionMessages`.
///
/// Every context string is used ONLY to help the model infer better trigger
/// keys — none of it is ever emitted as a lorebook entry.
List<Map<String, String>> buildLorebookMessages(
  String lorebookText, {
  String card = '',
  String catalog = '',
  String scenario = '',
  String greetings = '',
  String lorebookDescs = '',
  String extra = '',
  bool fromJs = false,
  bool fromFullPrompt = false,
}) {
  final userParts = <String>[];
  void add(String value, String intro) {
    if (value.trim().isNotEmpty) userParts.add('$intro\n\n${value.trim()}');
  }

  add(card,
      'CONTEXT — the character card these entries accompany. Use it ONLY to infer better trigger keys and resolve names/aliases. Do NOT output any of this card text as entries:');
  add(catalog,
      'CONTEXT — the public catalog description for this character as shown on the site (setting, place and faction names). Use it ONLY to infer better trigger keys. Do NOT output any of this as entries:');
  add(scenario,
      'CONTEXT — the scenario / setup for this roleplay. Use it ONLY to infer better trigger keys (names, places, situations). Do NOT output any of this as entries:');
  add(greetings,
      "CONTEXT — the character's opening message(s) / greeting(s). Use them ONLY to infer better trigger keys (names, places, items mentioned). Do NOT output any of this as entries:");
  add(lorebookDescs,
      'CONTEXT — the public descriptions of lorebooks attached to this character (titles and descriptions only — the lorebook contents themselves are NOT included here). Use them ONLY to infer better trigger keys. Do NOT output any of this as entries:');
  add(extra,
      'CONTEXT — additional notes provided by the user (names, aliases, setting details). Use it ONLY to infer better trigger keys. Do NOT output any of this as entries:');

  userParts.add(fromFullPrompt
      ? 'Full assembled chat prompt to extract lorebook entries from:\n\n$lorebookText'
      : fromJs
          ? 'JavaScript lorebook source to convert into entries:\n\n$lorebookText'
          : 'Raw lorebook text to convert into entries:\n\n$lorebookText');

  final systemPrompt = fromFullPrompt
      ? _systemPromptFull
      : fromJs
          ? _systemPromptJs
          : _systemPrompt;

  return [
    {'role': 'system', 'content': systemPrompt},
    {'role': 'user', 'content': userParts.join('\n\n---\n\n')},
  ];
}

/// Strips markdown code fences and trims to the outermost JSON object/array.
/// Port of the extension's `stripFences`.
String _stripFences(String text) {
  var t = text.trim();
  final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$', caseSensitive: false)
      .firstMatch(t);
  if (fence != null) t = fence[1]!.trim();
  final first = t.indexOf(RegExp(r'[\[{]'));
  final last = [t.lastIndexOf('}'), t.lastIndexOf(']')].reduce((a, b) => a > b ? a : b);
  if (first >= 0 && last > first) t = t.substring(first, last + 1);
  return t;
}

/// Coerces the parsed JSON into a list of raw entry maps. Port of `coerceEntries`.
List<dynamic> _coerceEntries(dynamic parsed) {
  if (parsed is List) return parsed;
  if (parsed is Map) {
    final entries = parsed['entries'];
    if (entries is List) return entries;
    if (entries is Map) return entries.values.toList();
    if (parsed['lorebook'] is List) return parsed['lorebook'] as List;
  }
  return const [];
}

List<String> _asKeys(dynamic v) {
  if (v is List) {
    return v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
  }
  if (v is String) {
    return v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }
  return const [];
}

LorebookEntry _buildEntry(Map<String, dynamic> raw, int index) {
  final keys = _asKeys(raw['key'] ?? raw['keys'] ?? raw['keywords']);
  final secondary =
      _asKeys(raw['keysecondary'] ?? raw['secondary_keys'] ?? raw['keySecondary']);
  final content = (raw['content'] ?? raw['text'] ?? '').toString().trim();
  final comment = (raw['comment'] ??
          raw['title'] ??
          raw['name'] ??
          raw['category'] ??
          'Entry $index')
      .toString()
      .trim();
  final order = (raw['order'] is num)
      ? (raw['order'] as num).toInt()
      : (raw['priority'] is num)
          ? (raw['priority'] as num).toInt()
          : (raw['insertion_order'] is num)
              ? (raw['insertion_order'] as num).toInt()
              : 100;
  return LorebookEntry(
    id: 'jle_${DateTime.now().millisecondsSinceEpoch}_$index',
    comment: comment,
    keys: keys,
    secondaryKeys: secondary,
    content: content,
    order: order,
    constant: raw['constant'] == true,
    position: 'matchGlobal',
  );
}

/// Builds a [Lorebook] from [lorebookText] using the active LLM. [card] and
/// [catalog] are optional context for key inference. [name] is the lorebook
/// title; [characterId], when given, scopes the book to that character.
///
/// Throws [NoActiveConnectionException] when no connection is configured, or
/// [Exception] when the LLM response can't be parsed into entries.
Future<Lorebook> rebuildLorebookWithActiveLlm(
  Ref ref, {
  required String lorebookText,
  required String name,
  String card = '',
  String catalog = '',
  String scenario = '',
  String greetings = '',
  String lorebookDescs = '',
  String extra = '',
  bool fromJs = false,
  bool fromFullPrompt = false,
  String? characterId,
}) async {
  await ref.read(apiListProvider.future);
  final config = ref.read(activeApiConfigProvider);
  if (config == null || config.endpoint.isEmpty || config.model.isEmpty) {
    throw NoActiveConnectionException();
  }

  final messages = buildLorebookMessages(
    lorebookText,
    card: card,
    catalog: catalog,
    scenario: scenario,
    greetings: greetings,
    lorebookDescs: lorebookDescs,
    extra: extra,
    fromJs: fromJs,
    fromFullPrompt: fromFullPrompt,
  );
  final completer = Completer<String>();
  final transport = pickChatTransport(config.protocol);

  String? reasoningOut;
  String? rawJsonOut;
  unawaited(transport.stream(
    request: ChatTransportRequest(
      endpoint: config.endpoint,
      apiKey: config.apiKey,
      model: config.model,
      messages: messages,
      // Do NOT cap output tokens (0 → the transport omits `max_tokens`, like
      // JAR). On reasoning models `max_tokens` bounds the COMBINED reasoning +
      // content output, so any finite cap can be spent entirely on the thinking
      // stream — leaving `content` empty (finish_reason "length") before the
      // model ever emits the JSON. Let the provider's full budget apply.
      maxTokens: 0,
      temperature: 0.2,
      topP: 1.0,
      stream: false,
      useResponsesApi: config.useResponsesApi,
      // Disable the transport's default HTTP receive timeout (0 → no cap). This
      // is a single non-streaming request that reconstructs a whole lorebook
      // from a large prompt, so on a slow model it can legitimately take longer
      // than the default 2 min and must not be aborted with a receive timeout.
      receiveTimeoutMs: 0,
    ),
    cancelToken: CancelToken(),
    onComplete: (text, reasoning, {rawResponseJson}) {
      reasoningOut = reasoning;
      rawJsonOut = rawResponseJson;
      if (!completer.isCompleted) completer.complete(text);
    },
    onError: (error) {
      if (!completer.isCompleted) completer.completeError(error);
    },
  ));

  final raw = await completer.future;

  String clip(String? s, int n) =>
      s == null ? '' : (s.length > n ? '${s.substring(0, n)}…' : s);

  debugPrint('[janitor-rebuilder] model=${config.model} '
      'protocol=${config.protocol} endpoint=${config.endpoint}');
  debugPrint('[janitor-rebuilder] response text (${raw.length} chars): '
      '${clip(raw, 1000)}');
  if ((reasoningOut ?? '').isNotEmpty) {
    debugPrint('[janitor-rebuilder] reasoning (${reasoningOut!.length} chars): '
        '${clip(reasoningOut, 500)}');
  }
  if ((rawJsonOut ?? '').isNotEmpty) {
    debugPrint(
        '[janitor-rebuilder] rawResponseJson (${rawJsonOut!.length} chars): '
        '${clip(rawJsonOut, 2000)}');
  }

  if (raw.trim().isEmpty) {
    throw LorebookBuildException(
      'LLM returned an empty response. The model may have spent its token '
      'budget on reasoning, the response may have been filtered, or the '
      'transport could not read the content field. Open the details below to '
      'see the raw provider payload.',
      rawText: raw,
      reasoning: reasoningOut,
      rawResponseJson: rawJsonOut,
    );
  }

  dynamic parsed;
  try {
    parsed = jsonDecode(_stripFences(raw));
  } catch (_) {
    final preview = raw.length > 300 ? raw.substring(0, 300) : raw;
    throw LorebookBuildException(
      'LLM did not return valid JSON. First 300 chars:\n$preview',
      rawText: raw,
      reasoning: reasoningOut,
      rawResponseJson: rawJsonOut,
    );
  }

  final rawEntries = _coerceEntries(parsed);
  final entries = <LorebookEntry>[];
  for (var i = 0; i < rawEntries.length; i++) {
    final e = rawEntries[i];
    if (e is! Map) continue;
    final entry = _buildEntry(Map<String, dynamic>.from(e), i);
    if (entry.content.isEmpty) continue;
    entries.add(entry);
  }
  if (entries.isEmpty) {
    throw LorebookBuildException(
      'LLM produced no usable lorebook entries.',
      rawText: raw,
      reasoning: reasoningOut,
      rawResponseJson: rawJsonOut,
    );
  }

  debugPrint('[janitor-extractor] rebuilt ${entries.length} lorebook entries');

  return Lorebook(
    id: generateId(),
    name: name,
    enabled: true,
    activationScope: characterId != null ? 'character' : 'global',
    activationTargetId: characterId,
    entries: entries,
    updatedAt: currentTimestampSeconds(),
  );
}
