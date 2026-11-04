import 'dart:convert';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/aux_llm_client.dart';
import '../../../core/llm/tokenizer.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/lorebook.dart';
import '../../../core/utils/error_format.dart';
import '../../../core/utils/id_generator.dart';
import '../../../core/utils/time_helpers.dart';
import '../../settings/api_list_provider.dart';
import '../../settings/app_settings_provider.dart';
import 'catalog_error_source.dart';
import 'janitor_separate.dart';

/// Rebuilds raw, concatenated closed-lorebook text into structured
/// [LorebookEntry]s using Glaze's **active LLM connection** — a Dart port of
/// the SillyTavern `janitor-lorebook` frontend extension's `buildWithActiveLLM`.
///
/// The capture step (see `JanitorWebViewProxy.captureGenerateAlpha`) yields the
/// concatenated bodies of the entries the platform injected; this asks the LLM
/// to split them back into discrete, keyed World Info entries.

const String kLorebookSystemPrompt = '''You reconstruct a SillyTavern World Info (lorebook) from raw text.

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
const String kLorebookSystemPromptJs =
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

/// Thrown when no usable LLM connection is configured.
class NoActiveConnectionException implements Exception {
  @override
  String toString() => 'catalog_lorebooks_no_connection'.tr();
}

/// Thrown when the build LLM call returns nothing usable. Carries the raw
/// provider output so the UI can show a debug panel and the user can see what
/// actually came back (empty content, a reasoning-only response, a content
/// filter, etc.).
class LorebookBuildException implements Exception {
  final String message;

  /// Who the failure belongs to, so the UI can head the error block with
  /// "PROVIDER ERROR" rather than a bare "ERROR". Everything raised here is
  /// the provider's answer in one form or another, hence the default.
  final CatalogErrorSource source;

  /// The assistant text the transport surfaced (often empty on failure).
  final String rawText;

  /// Separate reasoning/thinking stream, if the model emitted one.
  final String? reasoning;

  /// The raw provider JSON payload (the most useful field for diagnosis).
  final String? rawResponseJson;

  /// The exception the transport threw, when this wraps one. Kept so callers
  /// can inspect the original (a `DioException` still carries the provider's
  /// response body) rather than only its rendered message.
  final Object? cause;

  LorebookBuildException(
    this.message, {
    this.source = CatalogErrorSource.provider,
    this.rawText = '',
    this.reasoning,
    this.rawResponseJson,
    this.cause,
  });

  /// A transport-level failure — a refused key, a rate limit, a dead endpoint.
  /// The message is rendered with the shared [formatError], so it reads like
  /// every other provider error in Glaze (`HTTP 401: Invalid API key`) instead
  /// of a raw `DioException` dump.
  LorebookBuildException.fromProvider(
    Object error, {
    this.rawText = '',
    this.reasoning,
    this.rawResponseJson,
  }) : message = formatError(error),
       source = CatalogErrorSource.provider,
       cause = error;

  /// The same failure, labelled with the request it came from when a build
  /// was split into several — "which one" is the first thing to know when
  /// part 14 of 20 breaks. [resumable] says the parts before it are kept and
  /// the next build picks up here.
  LorebookBuildException inPart(
    int part,
    int total, {
    bool resumable = false,
  }) => LorebookBuildException(
    (resumable
            ? 'catalog_lorebooks_err_part_resume'
            : 'catalog_lorebooks_err_part')
        .tr(args: ['$part', '$total', message]),
    source: source,
    rawText: rawText,
    reasoning: reasoning,
    rawResponseJson: rawResponseJson,
    cause: cause,
  );

  @override
  String toString() => message;
}

/// Floor under [lorebookBuildChunkBudget], so a tiny (or never configured)
/// context size can't shred the text into one-paragraph requests. Also the
/// smallest request size the extraction settings offer.
const int kMinLorebookBuildChunkTokens = 2000;

/// How much lorebook text one build request may carry on [config]: at most
/// [maxTokens] (the user's setting), and given the [fixedTokens] every request
/// repeats (system prompt plus context), at most half of what is left of the
/// context window — prompt and reply share it, and the reply is about as long
/// as the text.
int lorebookBuildChunkBudget(
  ApiConfig? config, {
  int fixedTokens = 0,
  int maxTokens = kDefaultLorebookBuildChunkTokens,
}) {
  var budget = maxTokens;
  final window = config?.contextSize ?? 0;
  if (window > 0) {
    final fit = (window - fixedTokens) ~/ 2;
    if (fit < budget) budget = fit;
  }
  return budget < kMinLorebookBuildChunkTokens
      ? kMinLorebookBuildChunkTokens
      : budget;
}

/// Splits captured lorebook text into pieces of at most [maxTokens] each,
/// cutting only between entry blocks (blank lines) so an entry stays whole in
/// one request. A single block larger than the budget is cut on line breaks,
/// and a single line larger than that by length — the last resort for text
/// that has no structure to cut along.
List<String> chunkLorebookText(String text, int maxTokens) {
  final chunks = <String>[];
  final current = <String>[];
  var currentTokens = 0;
  for (final block in splitEntries(text)) {
    for (final piece in _splitOversized(block, maxTokens, '\n')) {
      final tokens = estimateTokens(piece, useCache: false);
      if (currentTokens > 0 && currentTokens + tokens > maxTokens) {
        chunks.add(current.join('\n\n'));
        current.clear();
        currentTokens = 0;
      }
      current.add(piece);
      currentTokens += tokens;
    }
  }
  if (current.isNotEmpty) chunks.add(current.join('\n\n'));
  return chunks;
}

/// [text] cut into pieces of at most [maxTokens], packed greedily along
/// [separator] (line breaks, then nothing at all for a single overlong line).
List<String> _splitOversized(String text, int maxTokens, String separator) {
  final tokens = estimateTokens(text, useCache: false);
  if (tokens <= maxTokens) return [text];
  if (separator.isEmpty) {
    final step = math.max(1, text.length * maxTokens ~/ tokens);
    return [
      for (var i = 0; i < text.length; i += step)
        text.substring(i, math.min(i + step, text.length)),
    ];
  }
  final pieces = <String>[];
  final current = StringBuffer();
  var currentTokens = 0;
  for (final line in text.split(separator)) {
    for (final part in _splitOversized(line, maxTokens, '')) {
      final partTokens = estimateTokens(part, useCache: false);
      if (currentTokens > 0 && currentTokens + partTokens > maxTokens) {
        pieces.add(current.toString());
        current.clear();
        currentTokens = 0;
      }
      if (current.isNotEmpty) current.write(separator);
      current.write(part);
      currentTokens += partTokens;
    }
  }
  if (current.isNotEmpty) pieces.add(current.toString());
  return pieces;
}

/// Every request a build sends, in order: [buildLorebookMessages] once per
/// piece of [lorebookText] that fits [config]'s budget (see
/// [lorebookBuildChunkBudget]), each carrying the full context. Text that fits
/// one request — and any JavaScript source, which has to be read whole —
/// stays a single request, as does everything when [chunkTokens] (the
/// extraction setting) is 0.
List<List<Map<String, String>>> planLorebookBuild(
  String lorebookText, {
  ApiConfig? config,
  int chunkTokens = kDefaultLorebookBuildChunkTokens,
  String card = '',
  String catalog = '',
  String scenario = '',
  String greetings = '',
  String lorebookDescs = '',
  String extra = '',
  bool fromJs = false,
  String? systemPrompt,
}) {
  List<Map<String, String>> messagesFor(String text) => buildLorebookMessages(
    text,
    card: card,
    catalog: catalog,
    scenario: scenario,
    greetings: greetings,
    lorebookDescs: lorebookDescs,
    extra: extra,
    fromJs: fromJs,
    systemPrompt: systemPrompt,
  );

  if (fromJs || chunkTokens <= 0) return [messagesFor(lorebookText)];
  final fixed = messagesFor('').fold<int>(
    0,
    (sum, m) => sum + estimateTokens(m['content'] ?? ''),
  );
  final budget = lorebookBuildChunkBudget(
    config,
    fixedTokens: fixed,
    maxTokens: chunkTokens,
  );
  final chunks = chunkLorebookText(lorebookText, budget);
  if (chunks.length <= 1) return [messagesFor(lorebookText)];
  return [for (final chunk in chunks) messagesFor(chunk)];
}

/// The system prompt a build actually sends: the user's own, when they edited
/// it in the extraction settings, otherwise the built-in default for the kind
/// of source being rebuilt.
///
/// A blank override means "use the default" — that is what clearing the field
/// in the settings sheet does, and what an unset setting looks like.
String lorebookSystemPrompt(AppSettings? settings, {bool fromJs = false}) {
  final custom =
      (fromJs ? settings?.lorebookBuildPromptJs : settings?.lorebookBuildPrompt)
          ?.trim() ??
      '';
  if (custom.isNotEmpty) return custom;
  return fromJs ? kLorebookSystemPromptJs : kLorebookSystemPrompt;
}

/// The connection a lorebook build runs on, with the slot's model folded in:
/// the one picked for lorebook builds in the settings, or [active] while the
/// slot is left on "use the chat connection" — or points at a connection that
/// has since been deleted. Embedding connections never qualify.
ApiConfig? resolveLorebookBuildConfig(
  AppSettings? settings, {
  required List<ApiConfig> configs,
  required ApiConfig? active,
}) {
  final id = settings?.lorebookBuildApiConfigId ?? '';
  ApiConfig? config;
  if (id.isNotEmpty) config = configs.where((c) => c.id == id).firstOrNull;
  config ??= active;
  if (config == null || config.mode == 'embedding') return null;
  final model = settings?.lorebookBuildModel.trim() ?? '';
  return model.isEmpty ? config : config.copyWith(model: model);
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
  // System prompt to send. Defaults to the built-in one for this source kind;
  // the UI passes [lorebookSystemPrompt] so a preview shows exactly what the
  // build would send, edited prompt included.
  String? systemPrompt,
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

  userParts.add(fromJs
      ? 'JavaScript lorebook source to convert into entries:\n\n$lorebookText'
      : 'Raw lorebook text to convert into entries:\n\n$lorebookText');

  final system =
      systemPrompt ?? (fromJs ? kLorebookSystemPromptJs : kLorebookSystemPrompt);

  return [
    {'role': 'system', 'content': system},
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
    // Placeholder: [rebuildLorebookWithActiveLlm] numbers the entries once
    // every part is in, so ids stay unique across a split build.
    id: 'jle_$index',
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
/// Text too long for one request is built in several (see
/// [planLorebookBuild]), one after another, and the entries of every part
/// are merged into the one book. [onProgress] reports `(done, total)` before
/// each request and once at the end.
///
/// [partCache], when given, keeps the entries of every part that came back,
/// keyed by the exact request: a build that fails at part 14 of 20 resumes
/// there on the next try instead of paying for the first 13 again. It is
/// emptied once a build succeeds, so building again asks the model afresh.
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
  String? characterId,
  void Function(int done, int total)? onProgress,
  Map<String, List<LorebookEntry>>? partCache,
}) async {
  final configs = await ref.read(apiListProvider.future);
  final settings = await ref.read(appSettingsProvider.future);
  final config = resolveLorebookBuildConfig(
    settings,
    configs: configs,
    active: ref.read(activeApiConfigProvider),
  );
  if (config == null || config.endpoint.isEmpty || config.model.isEmpty) {
    throw NoActiveConnectionException();
  }

  final requests = planLorebookBuild(
    lorebookText,
    config: config,
    chunkTokens: settings.lorebookBuildChunkTokens,
    card: card,
    catalog: catalog,
    scenario: scenario,
    greetings: greetings,
    lorebookDescs: lorebookDescs,
    extra: extra,
    fromJs: fromJs,
    systemPrompt: lorebookSystemPrompt(settings, fromJs: fromJs),
  );
  if (requests.length > 1) {
    debugPrint('[janitor-rebuilder] text split into ${requests.length} parts');
  }

  final entries = <LorebookEntry>[];
  for (var i = 0; i < requests.length; i++) {
    onProgress?.call(i, requests.length);
    final messages = requests[i];
    // The model is part of the key: a part a different model built is not
    // what a retry on this one would return.
    final key = [
      config.id,
      config.model,
      for (final m in messages) m['content'] ?? '',
    ].join('\u0000');
    var part = partCache?[key];
    if (part == null) {
      try {
        part = await _buildPart(config, messages);
      } on LorebookBuildException catch (e) {
        if (requests.length == 1) rethrow;
        throw e.inPart(i + 1, requests.length, resumable: partCache != null);
      }
      partCache?[key] = part;
    }
    entries.addAll(part);
  }
  onProgress?.call(requests.length, requests.length);
  partCache?.clear();

  debugPrint('[janitor-extractor] rebuilt ${entries.length} lorebook entries');

  final stamp = DateTime.now().millisecondsSinceEpoch;
  return Lorebook(
    id: generateId(),
    name: name,
    // Never global: scoped to [characterId] when there is one, otherwise saved
    // switched off. See `convertJanitorScript`.
    enabled: false,
    activationScope: characterId != null ? 'character' : 'global',
    activationTargetId: characterId,
    entries: [
      for (var i = 0; i < entries.length; i++)
        entries[i].copyWith(id: 'jle_${stamp}_$i'),
    ],
    updatedAt: currentTimestampSeconds(),
  );
}

/// One build request: sends [messages] on [config] and parses the reply into
/// entries. Throws [LorebookBuildException] for anything short of at least
/// one usable entry.
Future<List<LorebookEntry>> _buildPart(
  ApiConfig config,
  List<Map<String, String>> messages,
) async {
  String? reasoningOut;
  String? rawJsonOut;
  final String raw;
  try {
    // Same transport pipeline every other non-streaming call in Glaze uses —
    // protocol picked from the connection, prompt post-processing, extra
    // request parameters, retry policy and diagnostics all included. The
    // rebuild deliberately owns no separate HTTP path of its own.
    raw = await const AuxLlmClient().callOnce(
      config: AuxApiConfig(
        endpoint: config.endpoint,
        apiKey: config.apiKey,
        model: config.model,
        protocol: config.protocol,
        useResponsesApi: config.useResponsesApi,
        omitTemperature: config.omitTemperature,
        extraRequestParameters: config.extraRequestParameters,
      ),
      messages: messages,
      // Do NOT cap output tokens (0 → the transport omits `max_tokens`, like
      // JAR). On reasoning models `max_tokens` bounds the COMBINED reasoning +
      // content output, so any finite cap can be spent entirely on the thinking
      // stream — leaving `content` empty (finish_reason "length") before the
      // model ever emits the JSON. Let the provider's full budget apply.
      maxTokens: 0,
      temperature: 0.2,
      // 0 → no idle guard and no HTTP receive timeout. This is a
      // non-streaming request that reconstructs up to a whole lorebook from a
      // large prompt, so on a slow model it can legitimately take far longer than the
      // default two minutes and must not be cut off underneath the user.
      timeoutMs: 0,
      onRawResponse: (reasoning, rawResponseJson) {
        reasoningOut = reasoning;
        rawJsonOut = rawResponseJson;
      },
    );
  } catch (e) {
    // Everything the transport reports is the provider's answer: render it the
    // way the chat renders a failed generation instead of leaking a raw
    // `DioException` into the sheet.
    throw LorebookBuildException.fromProvider(
      e,
      reasoning: reasoningOut,
      rawResponseJson: rawJsonOut,
    );
  }

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
      'catalog_lorebooks_err_empty'.tr(),
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
      'catalog_lorebooks_err_json'.tr(args: [preview]),
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
      'catalog_lorebooks_err_no_entries'.tr(),
      rawText: raw,
      reasoning: reasoningOut,
      rawResponseJson: rawJsonOut,
    );
  }
  return entries;
}
