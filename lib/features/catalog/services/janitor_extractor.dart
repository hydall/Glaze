import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/lorebook.dart';
import '../../../core/state/lorebook_provider.dart';
import '../catalog_models.dart';
import '../catalog_provider.dart';
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

  /// True when the character has at least one "advanced" (Nine API / JS)
  /// lorebook. Those inject their entries inline inside the persona, so the
  /// mechanical [lorebookText] misses them — [fullPromptText] is rebuilt with the
  /// LLM in full-prompt mode instead. See [JanitorExtractor.buildLorebook].
  final bool hasAdvancedLorebook;

  /// The full captured system prompt (leading jailbreak stripped), used as the
  /// extraction material when [hasAdvancedLorebook] is true.
  final String fullPromptText;

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
    this.hasAdvancedLorebook = false,
    this.fullPromptText = '',
  });

  bool get hasLorebook => lorebookText.trim().isNotEmpty;

  /// Whether there is anything to rebuild: either mechanically-separated closed
  /// lorebook text, or a full prompt to mine for inline advanced-lorebook entries.
  bool get hasExtractable =>
      hasLorebook || (hasAdvancedLorebook && fullPromptText.trim().isNotEmpty);
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
  Future<ExtractionResult> extract(
    String url, {
    void Function(String phase)? onPhase,
  }) async {
    final characterId = _parseCharacterId(url);
    final proxy = JanitorWebViewProxy.instance;
    proxy.setActive(true);
    try {
      // Catalog meta gives the public name/tags/scenario and first message we
      // use both as LLM context and as extra trigger text for keyword matches.
      onPhase?.call('fetching metadata');
      final meta = await _fetchMeta(characterId);
      final catalog = _buildCatalogContext(meta);
      final firstMessageMeta = (meta?['first_message'] ?? '').toString();

      // Fetch the character's public lorebooks once: their verbatim entry
      // contents are subtracted from the closed-lorebook text (so public
      // content never leaks into the closed book), and their titles/page
      // descriptions feed the build LLM's key inference.
      final publicBooks = await fetchPublicLorebooks(meta);
      final publicContents = publicEntryContents(publicBooks);

      final payload = await proxy.captureGenerateAlpha(
        characterId: characterId,
        triggerText: firstMessageMeta,
        onPhase: onPhase,
      );

      onPhase?.call('separating');
      final card = extractCard(payload);
      final sep = separate(payload, card, publicContents);
      final advanced = hasAdvancedLorebook(meta);
      final fullPrompt = advanced
          ? stripLeadingJailbreak(getSystemContent(payload))
          : '';

      final name = extractCharName(payload).isNotEmpty
          ? extractCharName(payload)
          : (meta?['name'] ?? 'Unknown').toString();
      final scenario = extractScenario(payload).isNotEmpty
          ? extractScenario(payload)
          : (meta?['scenario'] ?? '').toString();
      final firstMes = extractFirstMessage(payload).isNotEmpty
          ? extractFirstMessage(payload)
          : firstMessageMeta;
      final example = extractExample(payload);
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
        ),
        avatarUrl: avatar,
      );

      final greetings = [
        firstMes,
        ...downloaded.charData.alternateGreetings,
      ].where((g) => g.trim().isNotEmpty).join('\n\n---\n\n');

      return ExtractionResult(
        characterId: characterId,
        sourceUrl: url,
        character: downloaded,
        lorebookText: sep.lorebookText,
        entryBlockCount: sep.entries.length,
        cardContext: card,
        catalogContext: catalog,
        scenarioContext: scenario,
        greetingsContext: greetings,
        lorebookDescsContext: buildLorebookDescsContext(publicBooks),
        hasAdvancedLorebook: advanced,
        fullPromptText: fullPrompt,
      );
    } finally {
      proxy.setActive(false);
    }
  }

  /// Phase 2: import the recovered character into the Glaze DB, then (if there
  /// is lorebook text) rebuild it with the active LLM and persist it scoped to
  /// the new character. A lorebook failure does not discard the character — it
  /// is reported via [CommitResult.lorebookError].
  Future<CommitResult> commit(
    ExtractionResult result, {
    void Function(String phase)? onPhase,
  }) async {
    onPhase?.call('importing character');
    final glazeId = await _ref
        .read(catalogProvider.notifier)
        .importCharacter(result.character, sourceUrl: result.sourceUrl);

    if (!result.hasExtractable) {
      return CommitResult(
        glazeCharacterId: glazeId,
        characterName: result.character.charData.name,
        lorebookEntryCount: 0,
      );
    }

    // An advanced (Nine API) lorebook injects entries inline in the persona, so
    // the mechanical separation misses them — feed the full prompt to the LLM and
    // let it pull the entries out using the context blocks as the base card.
    final fromFull = result.hasAdvancedLorebook;
    try {
      onPhase?.call('rebuilding lorebook (LLM)');
      final lorebook = await rebuildLorebookWithActiveLlm(
        _ref,
        lorebookText: fromFull ? result.fullPromptText : result.lorebookText,
        name: '${result.character.charData.name} — Closed Lorebook',
        card: result.cardContext,
        catalog: result.catalogContext,
        scenario: result.scenarioContext,
        greetings: result.greetingsContext,
        lorebookDescs: result.lorebookDescsContext,
        fromFullPrompt: fromFull,
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
        lorebookError: e.toString(),
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
    bool fromFullPrompt = false,
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
    fromFullPrompt: fromFullPrompt,
    characterId: characterId,
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
