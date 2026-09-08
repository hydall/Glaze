import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/models/lorebook.dart';
import '../../../core/utils/id_generator.dart';
import '../../../core/utils/time_helpers.dart';
import 'janitor_webview_proxy.dart';

/// Public lorebooks attached to a JanitorAI character.
///
/// Dart port of JAR's `publiclore.js` + `worldinfo.js`. A character can have
/// **public** lorebooks listed in its `scripts` metadata (`type:"lorebook"`,
/// or the newer `type:"advanced"`).
/// Unlike a *closed* lorebook — which only surfaces as triggered text inside a
/// `generateAlpha` response and must be rebuilt by an LLM (see
/// [JanitorExtractor]) — a public lorebook can be downloaded whole, in its
/// original structured form, from:
///
///   GET https://janitorai.com/hampter/script/{scriptId}
///
/// whose JSON has a `script` field (a JSON **string**) holding the entries in
/// JanitorAI's native shape. That array maps onto a Glaze [Lorebook] (or a
/// SillyTavern World Info `.json` for export).

/// A lorebook script reference ({id, title, isPublic}) attached to a character.
class JanitorScriptRef {
  final String id;
  final String title;
  final bool isPublic;
  const JanitorScriptRef({
    required this.id,
    required this.title,
    required this.isPublic,
  });
}

/// One fetched public lorebook. [accessible] is false when the script could not
/// be downloaded or yielded no entries (the closed-lorebook LLM path is then the
/// only way to recover it).
class PublicLorebook {
  final String id;
  final String title;
  final String description;
  final bool accessible;
  final int entryCount;

  /// The raw JanitorAI entries (native shape) — kept so the caller can build a
  /// Glaze [Lorebook] ([toLorebook]) or a SillyTavern `.json` ([toTavernJson]).
  final List<dynamic> rawEntries;
  final String? error;

  /// True when the downloaded script is JavaScript (a JanitorAI "advanced" /
  /// Nine API lorebook) rather than a JSON entries array. Such a book is public
  /// (we have its source) but can't be mapped 1:1 — it must be rebuilt into
  /// keyed entries with the build LLM ([JanitorExtractor.buildLorebookFromJs]).
  final bool isJs;

  /// The raw JavaScript source when [isJs] is true; empty otherwise.
  final String jsSource;

  const PublicLorebook({
    required this.id,
    required this.title,
    this.description = '',
    this.accessible = false,
    this.entryCount = 0,
    this.rawEntries = const [],
    this.error,
    this.isJs = false,
    this.jsSource = '',
  });

  /// Convert to a Glaze [Lorebook]. When [characterId] is given the book is
  /// scoped to that character, otherwise global.
  Lorebook toLorebook({String? characterId}) => convertJanitorScript(
        rawEntries,
        name: title.isNotEmpty ? title : 'Janitor Lorebook',
        characterId: characterId,
      );

  /// Convert to a SillyTavern World Info `{entries:{...}}` map for `.json`
  /// export.
  Map<String, dynamic> toTavernJson() =>
      janitorScriptToTavernJson(rawEntries, name: title);
}

const _origin = 'https://janitorai.com';

/// Lorebook script references attached to [meta] (`/hampter/characters/{id}`).
List<JanitorScriptRef> lorebookScriptRefs(Map<String, dynamic>? meta) {
  final scripts = meta?['scripts'];
  if (scripts is! List) return const [];
  return scripts
      .whereType<Map<String, dynamic>>()
      .where((s) =>
          (s['type'] == 'lorebook' || s['type'] == 'advanced') &&
          s['id'] != null)
      .map((s) => JanitorScriptRef(
            id: s['id'].toString(),
            title: (s['title'] ?? '').toString(),
            isPublic: s['is_public'] != false,
          ))
      .toList();
}

/// True when the character lists at least one JanitorAI **"advanced"** (Nine
/// API / JS) lorebook script in its metadata. Such scripts inject their entries
/// INLINE inside the persona block (not as discrete trailing blocks), so the
/// mechanical [separate] can't isolate them — the whole captured prompt must be
/// handed to the build LLM (`fromFullPrompt`) instead. Public or private alike:
/// a private advanced script can't be downloaded, and a public one still
/// pollutes the captured persona, so either way the full-prompt path is used.
bool hasAdvancedLorebook(Map<String, dynamic>? meta) {
  final scripts = meta?['scripts'];
  if (scripts is! List) return false;
  return scripts
      .whereType<Map<String, dynamic>>()
      .any((s) => s['type'] == 'advanced');
}

/// Parse the entries array out of a `/hampter/script/<id>` record (the `script`
/// field is a JSON **string** holding an array).
List<dynamic> parseScriptEntries(dynamic rec) {
  if (rec is! Map) return const [];
  final raw = rec['script'];
  if (raw is List) return raw;
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final a = jsonDecode(raw);
      return a is List ? a : const [];
    } catch (_) {
      return const [];
    }
  }
  return const [];
}

/// The raw JavaScript source of a `/hampter/script/<id>` record when its
/// `script` field is JS rather than a JSON entries array (a JanitorAI
/// "advanced" / Nine API lorebook). Returns '' when the script is JSON, empty,
/// or absent.
String _jsScriptSource(dynamic rec) {
  if (rec is! Map) return '';
  final raw = rec['script'];
  if (raw is! String) return '';
  final s = raw.trim();
  if (s.isEmpty) return '';
  // If it parses as a JSON array it's the structured (non-JS) shape.
  try {
    final a = jsonDecode(s);
    if (a is List) return '';
  } catch (_) {
    // Not JSON → treat as JS source.
  }
  return s;
}

/// The lorebook's human-readable description shown on its public page
/// (`/scripts/{id}`). JanitorAI does **not** expose this through the `/hampter`
/// API (its `description` there is usually empty) — it lives in the page's
/// embedded store as `scriptPublishedContent.content` (with `script.description`
/// as a fallback). The page embeds the store as escaped JSON inside a
/// `window.mbxM.push(JSON.parse("…"))` call, so it is double-decoded here.
/// Returns '' when the page is closed/unavailable or carries no content.
String _parsePublishedContent(String html) {
  final re = RegExp(r'JSON\.parse\("((?:[^"\\]|\\.)*)"\)');
  for (final m in re.allMatches(html)) {
    dynamic obj;
    try {
      final jsonText = jsonDecode('"${m.group(1)}"') as String;
      obj = jsonDecode(jsonText);
    } catch (_) {
      continue;
    }
    if (obj is! Map) continue;
    for (final v in obj.values) {
      if (v is! Map) continue;
      final spc = v['scriptPublishedContent'];
      if (spc is Map) {
        final c = spc['content'];
        if (c is String && c.trim().isNotEmpty) return c;
      }
      final sc = v['script'];
      if (sc is Map) {
        final d = sc['description'];
        if (d is String && d.trim().isNotEmpty) return d;
      }
    }
  }
  return '';
}

/// Fetch the lorebook's public page and pull out its description content.
/// Never throws — returns '' when the page can't be read (e.g. closed page).
Future<String> _fetchScriptDescription(String scriptId) async {
  try {
    final body =
        await JanitorWebViewProxy.instance.fetch('$_origin/scripts/$scriptId');
    return _parsePublishedContent(body);
  } catch (e) {
    debugPrint('[janitor-public-lore] scripts page $scriptId failed: $e');
    return '';
  }
}

/// Fetch a single public lorebook by script id. Never throws — on any failure
/// it returns a record with `accessible:false` so the caller can flag it as
/// "private / download-blocked" (those go through the closed-lorebook LLM path).
Future<PublicLorebook> fetchPublicLorebook(
  String scriptId, {
  String title = '',
}) async {
  try {
    final body = await JanitorWebViewProxy.instance
        .fetch('$_origin/hampter/script/$scriptId');
    final rec = jsonDecode(body);
    if (rec is! Map) {
      return PublicLorebook(
          id: scriptId, title: title, error: 'response was not JSON');
    }
    // The real description lives on the lorebook's public /scripts page, not in
    // the /hampter record (whose `description` is usually empty). Stored as
    // plain text (closed pages fall back to the empty hampter description).
    final pageDesc = await _fetchScriptDescription(scriptId);
    final description = _stripHtml(
        pageDesc.isNotEmpty ? pageDesc : (rec['description'] ?? '').toString());
    final entries = parseScriptEntries(rec);
    final usable = entries
        .whereType<Map<String, dynamic>>()
        .where((e) => (e['content'] ?? '').toString().trim().isNotEmpty)
        .length;
    // A JanitorAI "advanced" / Nine API lorebook ships its `script` as JavaScript
    // source, not a JSON entries array — so it yields no usable JSON entries even
    // though the script IS public. Surface it as a JS book (rebuilt via the LLM)
    // instead of silently flagging it private.
    final jsSource = usable == 0 ? _jsScriptSource(rec) : '';
    if (jsSource.isNotEmpty) {
      return PublicLorebook(
        id: (rec['id'] ?? scriptId).toString(),
        title: (rec['title'] ?? title).toString(),
        description: description,
        isJs: true,
        jsSource: jsSource,
      );
    }
    return PublicLorebook(
      id: (rec['id'] ?? scriptId).toString(),
      title: (rec['title'] ?? title).toString(),
      description: description,
      // Downloadable only if it actually yielded entries with content.
      accessible: usable > 0,
      entryCount: usable,
      rawEntries: entries,
    );
  } catch (e) {
    debugPrint('[janitor-public-lore] fetch $scriptId failed: $e');
    return PublicLorebook(id: scriptId, title: title, error: e.toString());
  }
}

/// Fetch every public lorebook attached to a character (from its metadata).
Future<List<PublicLorebook>> fetchPublicLorebooks(
  Map<String, dynamic>? meta,
) async {
  final refs = lorebookScriptRefs(meta);
  final out = <PublicLorebook>[];
  for (final ref in refs) {
    out.add(await fetchPublicLorebook(ref.id, title: ref.title));
  }
  return out;
}

/// Build the "lorebook descriptions" key-inference context from fetched public
/// lorebooks. Each book contributes its page **title** and, when its page is
/// accessible, its page **description** (`- Title: description`). A closed or
/// description-less page contributes only its title (`- Title`). The lorebook
/// *contents* are never included — only the public page description.
///
/// JanitorAI only exposes lorebook titles in the character's `scripts` metadata;
/// the descriptions live on each lorebook's own `/hampter/script/{id}` page, so
/// they must come from the fetched [PublicLorebook] records.
String buildLorebookDescsContext(List<PublicLorebook> books) {
  final lines = <String>[];
  for (final b in books) {
    final title = b.title.trim();
    final desc = _stripHtml(b.description);
    if (title.isEmpty && desc.isEmpty) continue;
    lines.add(desc.isEmpty ? '- $title' : '- $title: $desc');
  }
  return lines.join('\n');
}

/// Minimal HTML → plain text for lorebook page descriptions (which may carry
/// markup). Mirrors the extractor's `_htmlToText`.
String _stripHtml(String html) {
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

/// The verbatim entry contents of accessible public lorebooks — subtracted from
/// the closed-lorebook extraction so public content never leaks into it (see
/// JanitorSeparate / JAR `separate()`).
List<String> publicEntryContents(List<PublicLorebook> books) {
  final out = <String>[];
  for (final b in books) {
    if (!b.accessible) continue;
    for (final e in b.rawEntries) {
      if (e is Map) {
        final c = (e['content'] ?? '').toString();
        if (c.trim().isNotEmpty) out.add(c);
      }
    }
  }
  return out;
}

/// Split raw captured lorebook text into keyless entries (one per blank-line
/// separated block), in JanitorAI's native shape. Used by the "download raw"
/// path so the same [convertJanitorScript] / [janitorScriptToTavernJson]
/// builders produce a Glaze [Lorebook] or a SillyTavern `.json` with no trigger
/// keys/rules. Port of JAR `app.js` `downloadRaw`.
List<Map<String, dynamic>> rawLorebookEntries(String text) {
  final blocks = text
      .split(RegExp(r'\n\s*\n'))
      .map((b) => b.trim())
      .where((b) => b.isNotEmpty)
      .toList();
  return [
    for (var i = 0; i < blocks.length; i++)
      {'content': blocks[i], 'comment': 'Entry ${i + 1}', 'key': <String>[]},
  ];
}

// ─── Conversion ──────────────────────────────────────────────────────────────

List<String> _asKeys(dynamic v) {
  if (v is List) {
    return v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
  }
  if (v is String) {
    return v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }
  return const [];
}

int _asOrder(Map<String, dynamic> e) {
  for (final k in ['order', 'insertion_order', 'priority']) {
    final v = e[k];
    if (v is num) return v.toInt();
  }
  return 100;
}

/// JanitorAI numeric/string position → Glaze position token. Mirrors the
/// mapping in `character_book_converter.dart`.
String _mapPosition(dynamic pos) {
  if (pos is String) {
    switch (pos) {
      case 'before_char':
      case 'before_character':
      case 'worldInfoBefore':
        return 'worldInfoBefore';
      case 'at_depth':
      case 'lorebooksMacro':
        return 'lorebooksMacro';
      default:
        return 'worldInfoAfter';
    }
  }
  if (pos is num) {
    switch (pos.toInt()) {
      case 0:
      case 2:
      case 4:
        return 'worldInfoBefore';
      default:
        return 'worldInfoAfter';
    }
  }
  return 'worldInfoAfter';
}

/// Map JanitorAI's native entry shape → Glaze [LorebookEntry]. Tolerant of the
/// loose field names JanitorAI / SillyTavern use (`key`/`keys`/`keysRaw`, …).
LorebookEntry _toEntry(Map<String, dynamic> e, int index) {
  final keys = _asKeys(e['key'] ?? e['keys'] ?? e['keysRaw'] ?? e['keywords']);
  final secondary = _asKeys(
      e['keysecondary'] ?? e['secondary_keys'] ?? e['keySecondary']);
  final content = (e['content'] ?? e['text'] ?? '').toString();
  final comment =
      (e['comment'] ?? e['title'] ?? e['name'] ?? e['category'] ?? 'Entry $index')
          .toString()
          .trim();
  final rawProb = e['probability'];
  final probability = rawProb is num
      ? (rawProb <= 1 ? (rawProb * 100).round() : rawProb.round()).clamp(0, 100)
      : 100;
  final selectiveLogic =
      e['selectiveLogic'] is num ? (e['selectiveLogic'] as num).toInt() : 5;
  return LorebookEntry(
    id: 'jpl_${index}_${generateId()}',
    comment: comment,
    keys: keys,
    secondaryKeys: secondary,
    content: content,
    enabled: e['enabled'] != false && e['disable'] != true,
    constant: e['constant'] == true,
    position: _mapPosition(e['position']),
    order: _asOrder(e),
    selectiveLogic: selectiveLogic,
    probability: probability,
    caseSensitive: e['case_sensitive'] is bool ? e['case_sensitive'] as bool : null,
    matchWholeWords:
        e['match_whole_words'] is bool ? e['match_whole_words'] as bool : null,
    preventRecursion: e['prevent_recursion'] == true,
  );
}

/// Build a Glaze [Lorebook] from JanitorAI script [entries].
Lorebook convertJanitorScript(
  List<dynamic> entries, {
  required String name,
  String? characterId,
}) {
  final out = <LorebookEntry>[];
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    if (e is! Map) continue;
    final entry = _toEntry(Map<String, dynamic>.from(e), i);
    if (entry.content.trim().isEmpty) continue;
    out.add(entry);
  }
  return Lorebook(
    id: generateId(),
    name: name,
    enabled: true,
    activationScope: characterId != null ? 'character' : 'global',
    activationTargetId: characterId,
    entries: out,
    updatedAt: currentTimestampSeconds(),
  );
}

// ─── SillyTavern World Info export ───────────────────────────────────────────

int _tavernPosition(dynamic pos) {
  if (pos is num) return pos.toInt();
  switch (pos) {
    case 'before_char':
    case 'before_character':
    case 'worldInfoBefore':
      return 0;
    case 'at_depth':
    case 'lorebooksMacro':
      return 4;
    default:
      return 1;
  }
}

Map<String, dynamic> _tavernEntry(Map<String, dynamic> e, int uid) {
  final key = _asKeys(e['key'] ?? e['keys'] ?? e['keysRaw'] ?? e['keywords']);
  final keysecondary = _asKeys(
      e['keysecondary'] ?? e['secondary_keys'] ?? e['keySecondary']);
  final content = (e['content'] ?? e['text'] ?? '').toString().trim();
  final comment =
      (e['comment'] ?? e['title'] ?? e['name'] ?? e['category'] ?? 'Entry $uid')
          .toString()
          .trim();
  final constant = e['constant'] == true;
  final rawProb = e['probability'];
  final probability = rawProb is num
      ? (rawProb <= 1 ? (rawProb * 100).round() : rawProb.round())
      : 100;
  return {
    'uid': uid,
    'key': key,
    'keysecondary': keysecondary,
    'comment': comment,
    'content': content,
    'constant': constant,
    'selective': !constant,
    'order': _asOrder(e),
    'position': _tavernPosition(e['position']),
    'disable': e['enabled'] == false || e['disable'] == true,
    'displayIndex': uid,
    'addMemo': true,
    'group': '',
    'groupOverride': false,
    'groupWeight': 100,
    'sticky': 0,
    'cooldown': 0,
    'delay': 0,
    'probability': probability,
    'depth': 4,
    'useProbability': true,
    'role': null,
    'vectorized': false,
    'excludeRecursion': false,
    'preventRecursion': e['prevent_recursion'] == true,
    'delayUntilRecursion': false,
    'scanDepth': null,
    'caseSensitive':
        e['case_sensitive'] is bool ? e['case_sensitive'] : null,
    'matchWholeWords':
        e['match_whole_words'] is bool ? e['match_whole_words'] : null,
    'useGroupScoring': null,
    'automationId': '',
    'selectiveLogic':
        e['selectiveLogic'] is num ? (e['selectiveLogic'] as num).toInt() : 0,
    'ignoreBudget': false,
    'characterFilter': {'isExclude': false, 'names': <String>[], 'tags': <String>[]},
  };
}

/// Emit a SillyTavern World Info book (`{name, entries:{...}}`) for `.json`
/// export. Port of JAR `worldinfo.buildWorldInfo` / `buildEntry`.
Map<String, dynamic> janitorScriptToTavernJson(
  List<dynamic> entries, {
  String name = '',
}) {
  final out = <String, dynamic>{};
  var uid = 0;
  for (final e in entries) {
    if (e is! Map) continue;
    final entry = _tavernEntry(Map<String, dynamic>.from(e), uid);
    if ((entry['content'] as String).isEmpty) continue;
    out['$uid'] = entry;
    uid += 1;
  }
  return {
    if (name.isNotEmpty) 'name': name,
    'entries': out,
  };
}

int _glazeTavernPosition(String pos) {
  switch (pos) {
    case 'worldInfoBefore':
      return 0;
    case 'lorebooksMacro':
      return 4;
    default:
      return 1;
  }
}

/// Emit a SillyTavern World Info book from a Glaze [Lorebook] (e.g. a closed
/// lorebook freshly rebuilt by the LLM) for `.json` export.
Map<String, dynamic> glazeLorebookToTavernJson(Lorebook book) {
  final out = <String, dynamic>{};
  var uid = 0;
  for (final e in book.entries) {
    if (e.content.trim().isEmpty) continue;
    out['$uid'] = {
      'uid': uid,
      'key': e.keys,
      'keysecondary': e.secondaryKeys,
      'comment': e.comment,
      'content': e.content,
      'constant': e.constant,
      'selective': !e.constant,
      'order': e.order,
      'position': _glazeTavernPosition(e.position),
      'disable': !e.enabled,
      'displayIndex': uid,
      'addMemo': true,
      'group': e.group,
      'groupOverride': false,
      'groupWeight': 100,
      'sticky': e.sticky,
      'cooldown': e.cooldown,
      'delay': e.delay,
      'probability': e.probability,
      'depth': 4,
      'useProbability': true,
      'role': null,
      'vectorized': false,
      'excludeRecursion': false,
      'preventRecursion': e.preventRecursion,
      'delayUntilRecursion': false,
      'scanDepth': e.scanDepth,
      'caseSensitive': e.caseSensitive,
      'matchWholeWords': e.matchWholeWords,
      'useGroupScoring': null,
      'automationId': '',
      'selectiveLogic': e.selectiveLogic,
      'ignoreBudget': false,
      'characterFilter': {
        'isExclude': false,
        'names': <String>[],
        'tags': <String>[],
      },
    };
    uid += 1;
  }
  return {'name': book.name, 'entries': out};
}
