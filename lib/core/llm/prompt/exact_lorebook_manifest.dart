import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/lorebook.dart';
import '../macro_engine.dart';

const _schemaVersion = 1;
const _sources = {'constant', 'keyword', 'vector'};
const _classifications = {
  'worldInfoBefore',
  'worldInfoAfter',
  'lorebooksMacro',
  'charScenario',
  'charPersonality',
  'charDescription',
};
const _positions = {..._classifications, 'matchGlobal'};

/// Variation-independent prompt inputs. The hashes deliberately distinguish the
/// preset snapshot from the fully assembled provider message list.
final class ExactLorebookPromptProvenance {
  const ExactLorebookPromptProvenance({
    required this.characterId,
    required this.presetSnapshotHash,
    this.personaId = '',
    this.sessionId = '',
  });

  final String characterId;
  final String personaId;
  final String sessionId;
  final String presetSnapshotHash;

  Map<String, dynamic> toJson() => _map({
    'characterId': characterId,
    'personaId': personaId,
    'presetSnapshotHash': presetSnapshotHash,
    'sessionId': sessionId,
  });

  factory ExactLorebookPromptProvenance.fromJson(Map<String, dynamic> json) =>
      ExactLorebookPromptProvenance(
        characterId: json['characterId'] as String? ?? '',
        personaId: json['personaId'] as String? ?? '',
        sessionId: json['sessionId'] as String? ?? '',
        // Compatibility-only reader; durable decoding rejects this legacy key.
        presetSnapshotHash:
            json['presetSnapshotHash'] as String? ??
            json['promptTemplateHash'] as String? ??
            '',
      );
}

final class ExactLorebookEffectiveCanonProvenance {
  const ExactLorebookEffectiveCanonProvenance({
    required this.revisionNumber,
    required this.revisionHash,
    this.cacheIdentity = '',
  });
  final int revisionNumber;
  final String revisionHash;
  final String cacheIdentity;
  Map<String, dynamic> toJson() => _map({
    'cacheIdentity': cacheIdentity,
    'revisionHash': revisionHash,
    'revisionNumber': revisionNumber,
  });
  factory ExactLorebookEffectiveCanonProvenance.fromJson(
    Map<String, dynamic> json,
  ) => ExactLorebookEffectiveCanonProvenance(
    revisionNumber: json['revisionNumber'] as int? ?? 0,
    revisionHash: json['revisionHash'] as String? ?? '',
    cacheIdentity: json['cacheIdentity'] as String? ?? '',
  );
}

/// A full canonical post-merge [LorebookEntry] snapshot plus its exact emitted
/// content. Callers cannot provide a reduced substitute for [entry].
final class ExactLorebookManifestEntry {
  ExactLorebookManifestEntry.fromMergedEntry({
    required LorebookEntry entry,
    required this.source,
    required this.classification,
    required this.injectionIndex,
    required this.renderedContent,
  }) : entry = entry,
       rawContent = entry.content;

  final LorebookEntry entry;
  final String source;
  final String classification;
  final int injectionIndex;
  final String rawContent;
  final String renderedContent;

  String get lorebookId => entry.lorebookId;
  String get entryId => entry.id;
  String get name => entry.comment.isNotEmpty ? entry.comment : entry.id;
  String get position => entry.position;
  int get order => entry.order;
  String get namespacedId =>
      '${Uri.encodeComponent(lorebookId)}:${Uri.encodeComponent(entryId)}';
  String get rawContentHash => _hash(rawContent);
  String get renderedContentHash => _hash(renderedContent);

  Map<String, dynamic> toJson() => _map({
    'classification': classification,
    'entry': entry.toJson(),
    'entryId': entryId,
    'injectionIndex': injectionIndex,
    'lorebookId': lorebookId,
    'name': name,
    'namespacedId': namespacedId,
    'order': order,
    'position': position,
    'rawContent': rawContent,
    'rawContentHash': rawContentHash,
    'renderedContent': renderedContent,
    'renderedContentHash': renderedContentHash,
    'source': source,
  });

  ExactLorebookManifestEntry withRenderedContent(String content) =>
      ExactLorebookManifestEntry.fromMergedEntry(
        entry: entry,
        source: source,
        classification: classification,
        injectionIndex: injectionIndex,
        renderedContent: content,
      );

  ExactLorebookManifestEntry withInjectionIndex(int index) =>
      ExactLorebookManifestEntry.fromMergedEntry(
        entry: entry,
        source: source,
        classification: classification,
        injectionIndex: index,
        renderedContent: renderedContent,
      );

  factory ExactLorebookManifestEntry.fromJson(Map<String, dynamic> json) {
    final entryJson = json['entry'];
    if (entryJson is! Map) {
      throw const FormatException('Missing entry snapshot');
    }
    final entry = LorebookEntry.fromJson(Map<String, dynamic>.from(entryJson));
    final result = ExactLorebookManifestEntry.fromMergedEntry(
      entry: entry,
      source: json['source'] as String? ?? '',
      classification: json['classification'] as String? ?? '',
      injectionIndex: json['injectionIndex'] as int? ?? -1,
      renderedContent: json['renderedContent'] as String? ?? '',
    );
    _checkHash(json, 'rawContentHash', result.rawContentHash);
    _checkHash(json, 'renderedContentHash', result.renderedContentHash);
    return result;
  }
}

/// Explicit prompt-assembly event. An entry reaches a durable manifest only
/// after the assembler records this event; no final-message text searching is
/// used to infer injection.
final class ExactLorebookInjectionReport {
  const ExactLorebookInjectionReport({
    required this.namespacedId,
    required this.placement,
    required this.renderedContent,
    this.classification = '',
  });

  final String namespacedId;
  final int placement;
  final String renderedContent;
  final String classification;
}

final class ExactLorebookManifest {
  ExactLorebookManifest({
    required Iterable<ExactLorebookManifestEntry> entries,
    required this.promptProvenance,
    required this.providerMessagesHash,
    this.effectiveCanonProvenance,
  }) : entries = List.unmodifiable(_ordered(entries));

  final List<ExactLorebookManifestEntry> entries;
  final ExactLorebookPromptProvenance promptProvenance;
  final ExactLorebookEffectiveCanonProvenance? effectiveCanonProvenance;
  final String providerMessagesHash;

  ExactLorebookManifest withProviderMessagesHash(String value) =>
      ExactLorebookManifest(
        entries: entries,
        promptProvenance: promptProvenance,
        effectiveCanonProvenance: effectiveCanonProvenance,
        providerMessagesHash: value,
      );

  ExactLorebookManifest confirmedBy(
    Iterable<ExactLorebookInjectionReport> reports,
  ) {
    final byId = <String, ExactLorebookInjectionReport>{
      for (final report in reports) report.namespacedId: report,
    };
    final confirmed = <ExactLorebookManifestEntry>[];
    for (final entry in entries) {
      final report = byId[entry.namespacedId];
      if (report != null && report.renderedContent.trim().isNotEmpty) {
        confirmed.add(entry.withRenderedContent(report.renderedContent));
      }
    }
    return ExactLorebookManifest(
      entries: [
        for (var index = 0; index < confirmed.length; index++)
          confirmed[index].withInjectionIndex(index),
      ],
      promptProvenance: promptProvenance,
      effectiveCanonProvenance: effectiveCanonProvenance,
      providerMessagesHash: providerMessagesHash,
    );
  }

  ExactLorebookManifest confirmedForClassifications(
    Set<String> classifications,
  ) {
    final confirmed = entries
        .where((entry) => classifications.contains(entry.classification))
        .toList(growable: false);
    return ExactLorebookManifest(
      entries: [
        for (var index = 0; index < confirmed.length; index++)
          confirmed[index].withInjectionIndex(index),
      ],
      promptProvenance: promptProvenance,
      effectiveCanonProvenance: effectiveCanonProvenance,
      providerMessagesHash: providerMessagesHash,
    );
  }

  Map<String, dynamic> get canonicalMap => _map({
    'effectiveCanonProvenance': effectiveCanonProvenance?.toJson(),
    'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
    'promptProvenance': promptProvenance.toJson(),
    'providerMessagesHash': providerMessagesHash,
    'schemaVersion': _schemaVersion,
  });
  String get canonicalJson => jsonEncode(_canonicalize(canonicalMap));
  String get canonicalHash => _hash(canonicalJson);
  Map<String, dynamic> toJson() =>
      _map({...canonicalMap, 'canonicalHash': canonicalHash});

  /// Lenient runtime transport reader. Existing isolate payloads without a
  /// durable manifest remain compatible; use [decodeDurable] for persistence.
  factory ExactLorebookManifest.fromJson(Map<String, dynamic> json) =>
      _decode(json, strict: false);

  /// Fail-closed durable decoder: version, content hash, snapshots and all
  /// identity/order/enum invariants must be present and valid.
  factory ExactLorebookManifest.decodeDurable(Map<String, dynamic> json) =>
      _decode(json, strict: true);

  static ExactLorebookManifest _decode(
    Map<String, dynamic> json, {
    required bool strict,
  }) {
    if (strict) {
      _require(json['schemaVersion'] == _schemaVersion, 'schemaVersion');
    }
    final rawEntries = json['entries'];
    if (strict) _require(rawEntries is List, 'entries');
    final provenanceJson = json['promptProvenance'];
    if (strict) {
      _require(provenanceJson is Map, 'promptProvenance');
      _require(
        json['canonicalHash'] is String &&
            (json['canonicalHash'] as String).isNotEmpty,
        'canonicalHash',
      );
      _require(
        json['providerMessagesHash'] is String &&
            (json['providerMessagesHash'] as String).isNotEmpty,
        'providerMessagesHash',
      );
    }
    final manifest = ExactLorebookManifest(
      entries: (rawEntries as List? ?? const []).map((value) {
        if (strict) {
          _require(value is Map, 'entry');
        }
        return ExactLorebookManifestEntry.fromJson(
          Map<String, dynamic>.from(value as Map),
        );
      }),
      promptProvenance: ExactLorebookPromptProvenance.fromJson(
        Map<String, dynamic>.from(provenanceJson as Map? ?? const {}),
      ),
      effectiveCanonProvenance: json['effectiveCanonProvenance'] is Map
          ? ExactLorebookEffectiveCanonProvenance.fromJson(
              Map<String, dynamic>.from(
                json['effectiveCanonProvenance'] as Map,
              ),
            )
          : null,
      providerMessagesHash: json['providerMessagesHash'] as String? ?? '',
    );
    if (strict) _validateDurable(manifest, json);
    return manifest;
  }
}

ExactLorebookManifest buildExactLorebookManifest({
  required List<LorebookEntry> entries,
  required String characterId,
  required String personaId,
  required String sessionId,
  required String presetSnapshotHash,
  required MacroContext macroContext,
  required Map<String, String> sourceByEntryKey,
  required Map<String, String> classificationByEntryKey,
  ExactLorebookEffectiveCanonProvenance? effectiveCanonProvenance,
}) {
  final manifestEntries = <ExactLorebookManifestEntry>[];
  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index];
    final key = '${entry.lorebookId}_${entry.id}';
    manifestEntries.add(
      ExactLorebookManifestEntry.fromMergedEntry(
        entry: entry,
        source: sourceByEntryKey[key] ?? 'unknown',
        classification: classificationByEntryKey[key] ?? entry.position,
        injectionIndex: index,
        renderedContent: replaceMacros(entry.content, macroContext).text,
      ),
    );
  }

  return ExactLorebookManifest(
    entries: manifestEntries,
    promptProvenance: ExactLorebookPromptProvenance(
      characterId: characterId,
      personaId: personaId,
      sessionId: sessionId,
      presetSnapshotHash: presetSnapshotHash,
    ),
    effectiveCanonProvenance: effectiveCanonProvenance,
    providerMessagesHash: '',
  );
}

void _validateDurable(ExactLorebookManifest value, Map<String, dynamic> json) {
  _require(value.promptProvenance.characterId.isNotEmpty, 'characterId');
  _require(
    value.promptProvenance.presetSnapshotHash.isNotEmpty,
    'presetSnapshotHash',
  );
  _require(value.canonicalHash == json['canonicalHash'], 'canonicalHash');
  final ids = <String>{};
  for (var index = 0; index < value.entries.length; index++) {
    final entry = value.entries[index];
    _require(
      entry.lorebookId.isNotEmpty && entry.entryId.isNotEmpty,
      'entry ids',
    );
    _require(ids.add(entry.namespacedId), 'duplicate namespacedId');
    _require(entry.injectionIndex == index, 'injectionIndex');
    _require(_sources.contains(entry.source), 'source');
    _require(_classifications.contains(entry.classification), 'classification');
    _require(_positions.contains(entry.position), 'position');
  }
}

List<ExactLorebookManifestEntry> _ordered(
  Iterable<ExactLorebookManifestEntry> values,
) {
  final entries = values.toList()
    ..sort((a, b) => a.injectionIndex.compareTo(b.injectionIndex));
  for (var index = 0; index < entries.length; index++) {
    if (entries[index].injectionIndex != index) {
      throw ArgumentError('injection indexes must be contiguous');
    }
  }
  return entries;
}

Map<String, dynamic> _map(Map<String, dynamic> value) =>
    Map.unmodifiable(SplayTreeMap<String, dynamic>.from(value));
dynamic _canonicalize(dynamic value) {
  if (value is Map) {
    final sorted = SplayTreeMap<String, dynamic>();
    for (final entry in value.entries) {
      sorted[entry.key.toString()] = _canonicalize(entry.value);
    }
    return sorted;
  }
  if (value is Iterable) {
    return value.map(_canonicalize).toList(growable: false);
  }
  return value;
}

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();
void _checkHash(Map<String, dynamic> value, String key, String expected) {
  final supplied = value[key];
  if (supplied != null && supplied != expected) {
    throw FormatException('$key does not match manifest content');
  }
}

void _require(bool condition, String field) {
  if (!condition) {
    throw FormatException('Invalid durable lorebook manifest: $field');
  }
}
