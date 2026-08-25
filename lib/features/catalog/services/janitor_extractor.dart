import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/lorebook.dart';
import '../../../core/state/lorebook_provider.dart';
import '../catalog_models.dart';
import '../catalog_provider.dart';
import 'catalog_error_labels.dart';
import 'janitor_field_diff.dart';
import 'janitor_lorebook_rebuilder.dart';
import 'janitor_provider.dart';
import 'janitor_public_lorebook.dart';
import 'janitor_separate.dart';
import 'janitor_webview_proxy.dart';

/// Result of the capture+separate pass: the recovered character (with the
/// hidden card now in `description`), the isolated closed-lorebook text, and
/// the context used to rebuild it. No DB writes yet — the UI previews this,
/// then calls [JanitorExtractor.commit].
class ExtractionResult {
  final String characterId; // JanitorAI character UUID
  final String sourceUrl;
  final DownloadedCharacter character;
  final String lorebookText;
  final int entryBlockCount;
  final String cardContext;
  final String catalogContext;

  /// Text the field diff recovered from fields the character owns — the
  /// scenario, the persona, the example dialogue, the first message. Already
  /// part of [lorebookText]; kept apart so the UI can say where it came from.
  final List<InjectedBlock> injected;

  /// Extra context the lorebook-build LLM may use to infer better trigger keys
  /// (never emitted as entries). See `buildLorebookMessages`.
  final String scenarioContext;
  final String greetingsContext;
  final String lorebookDescsContext;

  const ExtractionResult({
    required this.characterId,
    required this.sourceUrl,
    required this.character,
    required this.lorebookText,
    required this.entryBlockCount,
    required this.cardContext,
    required this.catalogContext,
    this.scenarioContext = '',
    this.greetingsContext = '',
    this.lorebookDescsContext = '',
    this.injected = const [],
  });

  /// Whether there is any recovered text to rebuild into entries.
  bool get hasLorebook => lorebookText.trim().isNotEmpty;
}

/// Which blocks of the character's public context are stuffed into the message
/// Glaze sends into the JanitorAI chat to make the closed lorebook fire.
///
/// The lorebook itself lives on JanitorAI's server: it only reveals an entry
/// when something in the recent chat matches that entry's keys, so the trigger
/// message is the one lever the extraction has. Port of JAR's `exSources`, with
/// the same defaults — the card, the catalog description and the scenario are
/// dense with names and cheap; greetings and lorebook descriptions are opt-in.
class JanitorTriggerContext {
  /// The character card recovered by the capture's first send, re-sent so its
  /// names and places match as many entry keys as possible.
  final bool card;

  /// The character's catalog page: name, tags, description, scenario and the
  /// titles of the lorebooks attached to it.
  final bool catalog;
  final bool scenario;
  final bool greetings;

  /// Titles + page descriptions of the attached lorebooks.
  final bool lorebookDescs;

  /// Free-form text the user writes — the only way to reach entries of a
  /// generic/universe lorebook the character never names on its own.
  final String extra;

  const JanitorTriggerContext({
    this.card = true,
    this.catalog = true,
    this.scenario = true,
    this.greetings = false,
    this.lorebookDescs = false,
    this.extra = '',
  });
}

/// Summary returned after persisting an [ExtractionResult] to the DB.
class CommitResult {
  final String glazeCharacterId;
  final String characterName;
  final int lorebookEntryCount;
  final String? lorebookError;
  const CommitResult({
    required this.glazeCharacterId,
    required this.characterName,
    required this.lorebookEntryCount,
    this.lorebookError,
  });
}

/// Orchestrates the JanitorAI "closed lorebook + hidden card" extraction —
/// the Dart port of the SillyTavern `janitor-lorebook` extension's pipeline,
/// built on Glaze's own webview proxy ([JanitorWebViewProxy]) and active LLM.
class JanitorExtractor {
  JanitorExtractor(this._ref);
  final Ref _ref;

  static final _uuid = RegExp(
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
    caseSensitive: false,
  );

  /// Phase 1: capture the assembled prompt for [url] and separate it into the
  /// recovered card + isolated lorebook text. Marks the catalog active so the
  /// proxy WebView stays up for the duration.
  ///
  /// [trigger] picks which blocks of the character's public context are stuffed
  /// into the message that fires the closed lorebook — the more keywords it
  /// carries, the more entries JanitorAI's server injects into the prompt.
  Future<ExtractionResult> extract(
    String url, {
    JanitorTriggerContext trigger = const JanitorTriggerContext(),
    void Function(String phase)? onPhase,
    List<String> extraPublicContents = const [],
  }) async {
    final characterId = _parseCharacterId(url);
    final proxy = JanitorWebViewProxy.instance;
    proxy.setActive(true);
    try {
      // Catalog meta gives the public name/tags/scenario and first message we
      // use both as LLM context and as extra trigger text for keyword matches.
      onPhase?.call('fetching metadata');
      final meta = await _fetchMeta(characterId);
      // `allow_proxy: false` means the creator locked the card to JanitorAI's
      // own model: /generateAlpha would answer 403 and nothing could be
      // captured. Stop on the metadata instead of driving the whole capture to
      // reach the same refusal a minute later.
      if (!janitorAllowsProxy(meta)) {
        throw const JanitorRefusedException.proxyForbidden();
      }
      final metaCtx = contextFromMeta(meta);
      final catalog = metaCtx.catalog;

      // Fetch the character's public lorebooks once: their verbatim entry
      // contents are subtracted from the closed-lorebook text (so public
      // content never leaks into the closed book), and their titles/page
      // descriptions feed the build LLM's key inference.
      final publicBooks = await fetchPublicLorebooks(meta);
      // A public *script* has no entries to subtract until someone converts it
      // with the LLM; when the caller already did, it passes them in here so its
      // entries are cut out of the closed lorebook like any other public book's.
      final publicContents = [
        ...publicEntryContents(publicBooks),
        ...extraPublicContents,
      ];
      final lorebookDescs = buildLorebookDescsContext(publicBooks);

      // The trigger message: everything the user selected, concatenated into a
      // single latest user turn so every keyword stays within JanitorAI's
      // server-side scan depth. The card is added by the capture itself (it
      // only exists inside the assembled prompt, which the first send reveals).
      final triggerText = [
        if (trigger.catalog) metaCtx.catalog,
        if (trigger.scenario) metaCtx.scenario,
        if (trigger.greetings) metaCtx.greetings,
        if (trigger.lorebookDescs) lorebookDescs,
        trigger.extra,
      ].map((s) => s.trim()).where((s) => s.isNotEmpty).join('\n\n');

      final capture = await proxy.captureGenerateAlpha(
        characterId: characterId,
        triggerText: triggerText,
        includeCard: trigger.card,
        onPhase: onPhase,
      );
      final payload = capture.payload;

      onPhase?.call('separating');
      final rawCard = extractCard(payload);
      final sep = separate(payload, rawCard, publicContents);

      final name = extractCharName(payload).isNotEmpty
          ? extractCharName(payload)
          : (meta?['name'] ?? 'Unknown').toString();

      // JanitorAI expands {{char}} / {{user}} before assembling the prompt, so
      // every captured field carries baked names. Put the macros back so the
      // imported card and its lorebook stay portable. `{{user}}` is normally
      // already intact (the capture binds a persona named `{{user}}`);
      // [bakedUserName] is set only when that persona could not be created.
      final charNames = <String>{
        name,
        (meta?['name'] ?? '').toString(),
        (meta?['chat_name'] ?? '').toString(),
      }.where((n) => n.trim().isNotEmpty).toList();
      String macro(String text) => restoreMacros(
            text,
            charNames: charNames,
            userName: capture.bakedUserName,
          );

      final card = macro(rawCard);
      final scenario = macro(extractScenario(payload).isNotEmpty
          ? extractScenario(payload)
          : (meta?['scenario'] ?? '').toString());
      final example = macro(extractExample(payload));

      // Lore a script wrote INTO the character's own fields never reaches the
      // separator (it drops those blocks whole, and never reads the first
      // message at all). Recover it by diffing the captured prompt against the
      // capture's own "." probe, and — for a public definition only — the probe
      // against the catalog's clean fields. Everything is compared after macro
      // restoration, so the captured text (names expanded) lines up with the
      // catalog metadata (macros intact).
      final definitionPublic = meta != null && janitorDefinitionPublic(meta);
      final probePayload = capture.probePayload;
      final probeFields = probePayload == null
          ? null
          : PromptFields.fromPayload(probePayload, restore: macro);
      final cleanFields =
          definitionPublic ? PromptFields.fromMeta(meta) : null;
      final separated = macro(sep.lorebookText);
      final scan = scanInjectedFields(
        capture: PromptFields.fromPayload(payload, restore: macro),
        probe: probeFields,
        clean: cleanFields,
        publicContents: publicContents,
        existing: separated,
      );
      final lorebookText = [separated, scan.text]
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .join('\n\n');

      // Greetings, best source first: the chat object the capture created (it
      // carries them verbatim even when a closed card withholds them from
      // /hampter/characters), then the catalog metadata, then the assistant turn
      // in the captured prompt — which is the character's opening line and the
      // only place a fully withheld greeting survives.
      final greetingList = <String>[
        ...capture.greetings,
        if (meta?['first_message'] is String)
          (meta!['first_message'] as String),
        if (meta?['first_messages'] is List)
          ...(meta!['first_messages'] as List)
              .whereType<String>(),
        extractFirstMessage(payload),
      ]
          .map(macro)
          .map((g) => g.trim())
          .where((g) => g.isNotEmpty)
          .toSet()
          .toList();
      final firstMes = greetingList.isEmpty ? '' : greetingList.first;
      final alternateGreetings =
          greetingList.length > 1 ? greetingList.sublist(1) : const <String>[];

      final tags = (meta?['custom_tags'] is List)
          ? (meta!['custom_tags'] as List).map((e) => e.toString()).toList()
          : <String>[];
      final avatar = resolveJanitorAvatar(meta?['avatar'] as String?);

      final downloaded = DownloadedCharacter(
        charData: CharacterData(
          name: name,
          description: card,
          scenario: scenario,
          firstMes: firstMes,
          mesExample: example,
          creatorNotes: _htmlToText((meta?['description'] ?? '').toString()),
          tags: tags,
          creator: (meta?['creator_name'] ?? meta?['creator'] ?? '').toString(),
          creatorId: (meta?['creator_id'] ?? '').toString(),
          alternateGreetings: alternateGreetings,
        ),
        avatarUrl: avatar,
      );

      final greetings = greetingList.join('\n\n---\n\n');

      // The card and scenario play two different parts, and the captured text
      // is only right for one of them. For the IMPORT it is the truth (a closed
      // card exists nowhere else). As CONTEXT for the build it is the yardstick
      // the model uses to decide what is NOT lore — and the captured copy has
      // the injected lore baked into it, so handing it over would teach the
      // model to throw that lore away. Use the catalog's clean copy wherever
      // there is one; a closed card has none, and there the captured text is
      // still better than nothing.
      final cardContext = cleanFields != null &&
              cleanFields.persona.trim().isNotEmpty
          ? cleanFields.persona
          : card;
      final scenarioContext = cleanFields != null &&
              cleanFields.scenario.trim().isNotEmpty
          ? cleanFields.scenario
          : scenario;

      return ExtractionResult(
        characterId: characterId,
        sourceUrl: url,
        character: downloaded,
        lorebookText: lorebookText,
        entryBlockCount: splitEntries(lorebookText).length,
        cardContext: cardContext,
        catalogContext: catalog,
        scenarioContext: scenarioContext,
        greetingsContext: greetings,
        lorebookDescsContext: lorebookDescs,
        injected: scan.blocks,
      );
    } finally {
      proxy.setActive(false);
    }
  }

  /// Phase 2: import the recovered character into the Glaze DB, then (if there
  /// is lorebook text) rebuild it with the active LLM and persist it scoped to
  /// the new character. A lorebook failure does not discard the character — it
  /// is reported via [CommitResult.lorebookError].
  ///
  /// Pass `rebuildLorebook: false` to import the character only. The import
  /// flow uses that when the user picked "character" (or is going to drive the
  /// lorebook capture themselves in the lorebook sheet, which owns the context
  /// choices the automatic rebuild has to guess at); with
  /// `attachPublicLorebooks: true` the character's *public* books — which
  /// download whole and need neither a capture nor an LLM — are still pulled in
  /// and scoped to the new character.
  Future<CommitResult> commit(
    ExtractionResult result, {
    void Function(String phase)? onPhase,
    bool rebuildLorebook = true,
    bool attachPublicLorebooks = false,
    Map<String, dynamic>? janitorMeta,
  }) async {
    onPhase?.call('importing character');
    final glazeId = await _ref
        .read(catalogProvider.notifier)
        .importCharacter(
          result.character,
          sourceUrl: result.sourceUrl,
          attachLorebooks: attachPublicLorebooks,
          janitorMeta: janitorMeta,
        );

    if (!rebuildLorebook) {
      return CommitResult(
        glazeCharacterId: glazeId,
        characterName: result.character.charData.name,
        lorebookEntryCount: 0,
      );
    }

    if (!result.hasLorebook) {
      return CommitResult(
        glazeCharacterId: glazeId,
        characterName: result.character.charData.name,
        lorebookEntryCount: 0,
      );
    }

    try {
      onPhase?.call('rebuilding lorebook (LLM)');
      final lorebook = await rebuildLorebookWithActiveLlm(
        _ref,
        lorebookText: result.lorebookText,
        name: '${result.character.charData.name} — Closed Lorebook',
        card: result.cardContext,
        catalog: result.catalogContext,
        scenario: result.scenarioContext,
        greetings: result.greetingsContext,
        lorebookDescs: result.lorebookDescsContext,
        characterId: glazeId,
      );
      onPhase?.call('saving lorebook');
      await _ref.read(lorebooksProvider.notifier).put(lorebook);
      return CommitResult(
        glazeCharacterId: glazeId,
        characterName: result.character.charData.name,
        lorebookEntryCount: lorebook.entries.length,
      );
    } catch (e) {
      debugPrint('[janitor-extractor] lorebook rebuild failed: $e');
      return CommitResult(
        glazeCharacterId: glazeId,
        characterName: result.character.charData.name,
        lorebookEntryCount: 0,
        lorebookError: describeCatalogError(
          e,
          fallback: CatalogErrorSource.provider,
        ).inline,
      );
    }
  }

  /// Rebuilds [lorebookText] into a structured [Lorebook] with the active LLM,
  /// using the selected context strings for key inference. Used by the catalog
  /// Lorebooks tab's "Build" action (the extractor owns the provider [Ref] that
  /// `rebuildLorebookWithActiveLlm` needs). [characterId] scopes the book.
  Future<Lorebook> buildLorebook({
    required String lorebookText,
    required String name,
    String card = '',
    String catalog = '',
    String scenario = '',
    String greetings = '',
    String lorebookDescs = '',
    String extra = '',
    String? characterId,
  }) => rebuildLorebookWithActiveLlm(
    _ref,
    lorebookText: lorebookText,
    name: name,
    card: card,
    catalog: catalog,
    scenario: scenario,
    greetings: greetings,
    lorebookDescs: lorebookDescs,
    extra: extra,
    characterId: characterId,
  );

  /// The key-inference context that is knowable from the character's catalog
  /// metadata alone, before any capture has run.
  ///
  /// The character card is deliberately absent: it only exists inside the
  /// assembled prompt, so it is recovered by the capture itself. Everything
  /// else is public, which is what lets the capture sheet offer the same
  /// context selection *before* the rebuild — JAR's `exSources`, whose choices
  /// are carried straight into the build.
  ///
  /// Lorebook descriptions are not included here: the caller already has the
  /// public books and can pass them through `buildLorebookDescsContext`.
  ({String catalog, String scenario, String greetings}) contextFromMeta(
    Map<String, dynamic>? meta,
  ) => (
    catalog: _buildCatalogContext(meta),
    scenario: _htmlToText((meta?['scenario'] ?? '').toString()),
    greetings: _htmlToText((meta?['first_message'] ?? '').toString()),
  );

  /// Rebuilds a public **JavaScript** lorebook (a JanitorAI "advanced" / Nine
  /// API script) into a structured [Lorebook] with the active LLM. Unlike a JSON
  /// lorebook — which maps 1:1 — a JS script must be interpreted, so its source
  /// is sent to the build LLM (`fromJs`). Key-inference context (catalog,
  /// scenario, lorebook descriptions) is derived from [meta] (the character's
  /// `/hampter` metadata). [characterId] scopes the book when given.
  Future<Lorebook> buildLorebookFromJs({
    required String jsSource,
    required String name,
    Map<String, dynamic>? meta,
    String? characterId,
  }) async => rebuildLorebookWithActiveLlm(
    _ref,
    lorebookText: jsSource,
    name: name,
    catalog: _buildCatalogContext(meta),
    scenario: _htmlToText((meta?['scenario'] ?? '').toString()),
    lorebookDescs: await _lorebookDescs(meta),
    fromJs: true,
    characterId: characterId,
  );

  String _parseCharacterId(String input) {
    final m = _uuid.firstMatch(input.trim());
    if (m == null) {
      throw Exception('No character id found in: $input');
    }
    return m[0]!;
  }

  Future<Map<String, dynamic>?> _fetchMeta(String characterId) async {
    try {
      final body = await JanitorWebViewProxy.instance.fetch(
        'https://janitorai.com/hampter/characters/$characterId',
      );
      final json = jsonDecode(body);
      return json is Map<String, dynamic> ? json : null;
    } catch (e) {
      debugPrint('[janitor-extractor] meta fetch failed: $e');
      return null;
    }
  }

  /// Builds the catalog/world context block (port of `buildCatalogContext`).
  String _buildCatalogContext(Map<String, dynamic>? meta) {
    if (meta == null) return '';
    final parts = <String>[];
    final name = (meta['name'] ?? '').toString();
    if (name.isNotEmpty) parts.add('Name: $name');
    final tags = meta['custom_tags'];
    if (tags is List && tags.isNotEmpty) {
      parts.add('Tags: ${tags.join(', ')}');
    }
    final desc = _htmlToText((meta['description'] ?? '').toString());
    if (desc.isNotEmpty) parts.add('Catalog description:\n$desc');
    final scenario = _htmlToText((meta['scenario'] ?? '').toString());
    if (scenario.isNotEmpty) parts.add('Scenario:\n$scenario');
    final scripts = meta['scripts'];
    if (scripts is List) {
      final books = scripts
          .whereType<Map<String, dynamic>>()
          .where((s) => s['type'] == 'lorebook' || s['type'] == 'advanced')
          .map(
            (s) =>
                '- ${s['title'] ?? ''}${s['description'] != null ? ': ${s['description']}' : ''}',
          )
          .toList();
      if (books.isNotEmpty) {
        parts.add(
          'Attached lorebooks (titles only — contents are hidden):\n${books.join('\n')}',
        );
      }
    }
    return parts.join('\n\n');
  }

  /// Titles + page descriptions of the lorebooks attached to the character
  /// (contents stay hidden). Used as key-inference context for the build LLM.
  ///
  /// JanitorAI's character metadata only carries lorebook *titles*; each
  /// lorebook's description lives on its own `/hampter/script/{id}` page, so the
  /// pages are fetched and [buildLorebookDescsContext] combines title +
  /// description (title only when the page is closed/description-less).
  Future<String> _lorebookDescs(Map<String, dynamic>? meta) async {
    final books = await fetchPublicLorebooks(meta);
    return buildLorebookDescsContext(books);
  }

  /// Minimal HTML → text (port of `htmlToText`).
  String _htmlToText(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|div|li|h\d)>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'&#39;|&apos;'), "'")
        .replaceAll('&quot;', '"')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .trim();
  }
}

/// Provider for the JanitorAI extractor service.
final janitorExtractorProvider = Provider<JanitorExtractor>(
  (ref) => JanitorExtractor(ref),
);
