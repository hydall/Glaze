import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'json_repair.dart';
import '../models/character_knowledge_fact.dart';
import '../models/studio_ledger_export.dart';

// ─────────────────────────────────────────────────────────────────────────────
// StudioLedgerExportParser
//
// Extracts and validates the <glaze_memory_export> JSON block from the raw
// Studio Ledger LLM response (which also contains a <studio_ledger> visible
// block). Returns null when the block is absent, malformed, or wholly invalid.
//
// Validation rules: ledger output is treated as untrusted model output until
// parsed and validated. Reject unknown operations, unknown namespace prefixes,
// malformed JSON, future facts,
// completion of user actions/choices/threats/plans/offers without evidence in
// accepted chat. Skip locked fields. Ignore empty exports. Quarantine bad
// exports as diagnostics only.
//   - Reject unknown op codes.
//   - Reject unknown namespace prefixes.
//   - Reject malformed JSON.
//   - Skip locked fields (done at write-time by TrackerRepo).
//   - Ignore empty exports (no ops AND no knowledge facts).
//   - Quarantine bad exports, return null.
// ─────────────────────────────────────────────────────────────────────────────

/// Allowed namespace prefixes for op keys.
const Set<String> kAllowedNamespacePrefixes = {
  'npc:',
  'relationship:',
  'arc:',
  'world:',
  'scene.',
};

/// Allowed op codes.
const Set<String> kAllowedOpCodes = {'set', 'delete'};

/// Allowed event-state tokens (empty string = unset, allowed).
const Set<String> kAllowedEventStates = {
  '',
  'planned',
  'suggested',
  'threatened',
  'attempted',
  'completed',
  'failed',
  'cancelled',
  'unknown',
};

/// Result of parsing a Studio Ledger LLM response.
class LedgerParseResult {
  /// The validated export. Null when absent or wholly invalid.
  final StudioLedgerExport? export;

  /// The raw visible `studio_ledger` block text (may be empty if absent).
  final String visibleLedger;

  /// Human-readable rejection reason, for diagnostics.
  final String? rejectionReason;

  const LedgerParseResult({
    this.export,
    required this.visibleLedger,
    this.rejectionReason,
  });

  bool get hasExport => export != null;
  bool get wasRejected => rejectionReason != null;
}

/// Parses and validates the Studio Ledger LLM output.
///
/// Stateless — all methods are pure functions over the raw LLM text.
class StudioLedgerExportParser {
  const StudioLedgerExportParser();

  /// Parse the full LLM [rawOutput] and return a [LedgerParseResult].
  ///
  /// - Extracts the `<studio_ledger>…</studio_ledger>` visible block.
  /// - Extracts the `<glaze_memory_export>…</glaze_memory_export>` JSON block.
  /// - Validates the export (see class-level docs).
  /// - Returns null export + rejectionReason when invalid.
  LedgerParseResult parse(String rawOutput) {
    final visibleLedger = _extractBlock(rawOutput, 'studio_ledger');
    final exportRaw = _extractBlock(rawOutput, 'glaze_memory_export');

    if (exportRaw.isEmpty) {
      return LedgerParseResult(
        visibleLedger: visibleLedger,
        rejectionReason: 'no <glaze_memory_export> block found',
      );
    }

    StudioLedgerExport export;
    try {
      final jsonRaw = extractJsonObject(exportRaw);
      if (jsonRaw == null) {
        return LedgerParseResult(
          visibleLedger: visibleLedger,
          rejectionReason: 'export block does not contain a JSON object',
        );
      }
      final decoded = jsonDecode(repairJson(jsonRaw));
      if (decoded is! Map<String, dynamic>) {
        return LedgerParseResult(
          visibleLedger: visibleLedger,
          rejectionReason: 'export root is not a JSON object',
        );
      }
      export = StudioLedgerExport.fromJson(_normalizeExportJson(decoded));
    } catch (e) {
      debugPrint('[StudioLedger] JSON parse error: $e');
      return LedgerParseResult(
        visibleLedger: visibleLedger,
        rejectionReason: 'malformed JSON: $e',
      );
    }

    // Validate ops.
    final validatedOps = <LedgerOp>[];
    final rejectedOps = <String>[];

    for (final op in export.ops) {
      final reason = _validateOp(op);
      if (reason != null) {
        rejectedOps.add('${op.key}: $reason');
        debugPrint('[StudioLedger] rejected op ${op.op} ${op.key}: $reason');
      } else {
        validatedOps.add(op);
      }
    }

    if (rejectedOps.isNotEmpty) {
      debugPrint(
        '[StudioLedger] ${rejectedOps.length} ops rejected out of '
        '${export.ops.length}',
      );
    }

    final validatedFacts = _validateKnowledgeFacts(export.knowledgeFacts);

    // Ignore completely empty exports.
    final isEmpty = validatedOps.isEmpty && validatedFacts.isEmpty;
    if (isEmpty) {
      return LedgerParseResult(
        visibleLedger: visibleLedger,
        rejectionReason: rejectedOps.isNotEmpty
            ? 'all ops rejected, no knowledge facts'
            : 'empty export (no ops or knowledge facts)',
      );
    }

    final validatedExport = export.copyWith(
      ops: validatedOps,
      knowledgeFacts: validatedFacts,
    );
    return LedgerParseResult(
      export: validatedExport,
      visibleLedger: visibleLedger,
    );
  }

  // ── Extraction ─────────────────────────────────────────────────────────────

  /// Extract the inner text of `<[tag]>…</[tag]>` from [source].
  /// Returns an empty string when not found.
  ///
  /// When the opening tag is found but the closing tag is missing (common when
  /// the LLM response is truncated by max_tokens), returns everything after
  /// the opening tag to the end of the source — the downstream JSON repair +
  /// brace extraction can still recover a partial export.
  String _extractBlock(String source, String tag) {
    final open = '<$tag>';
    final close = '</$tag>';
    final start = source.indexOf(open);
    if (start < 0) return '';
    final contentStart = start + open.length;
    final end = source.indexOf(close, contentStart);
    if (end < 0) {
      // Truncated response — return everything after the opening tag.
      return source.substring(contentStart).trim();
    }
    return source.substring(contentStart, end).trim();
  }

  // ── LLM JSON normalization ────────────────────────────────────────────────

  /// Ledger output is produced by an LLM, so fields that are specified as
  /// strings sometimes arrive as lists or objects. Normalize those shapes before
  /// handing them to generated `fromJson` code so malformed optional diagnostics
  /// do not discard otherwise-valid ops.
  Map<String, dynamic> _normalizeExportJson(Map<String, dynamic> json) {
    return {
      'sceneState': _normalizeSceneState(json['sceneState']),
      'entities': _normalizeEntities(json['entities']),
      'arcState': _normalizeArcState(json['arcState']),
      'knowledgeFacts': _normalizeKnowledgeFacts(json['knowledgeFacts']),
      'ops': _normalizeOps(json['ops']),
    };
  }

  Map<String, dynamic>? _normalizeSceneState(dynamic value) {
    final map = _asMap(value);
    if (map == null) return null;
    return {
      'time': _stringValue(map['time']),
      'date': _stringValue(map['date']),
      'location': _stringValue(map['location']),
      'immediateThread': _stringValue(map['immediateThread']),
      'presentEntities': _normalizePresentEntities(map['presentEntities']),
      'activeTensions': _stringList(map['activeTensions']),
    };
  }

  List<Map<String, dynamic>> _normalizePresentEntities(dynamic value) {
    return _listItems(value)
        .map((item) {
          final map = _asMap(item);
          if (map == null) {
            return {
              'name': _stringValue(item),
              'status': 'present',
              'reason': '',
              'confidence': 'high',
            };
          }
          return {
            'name': _stringValue(map['name']),
            'status': _stringValue(map['status']).ifBlank('present'),
            'reason': _stringValue(map['reason']),
            'confidence': _stringValue(map['confidence']).ifBlank('high'),
          };
        })
        .where((item) => (item['name'] as String).isNotEmpty)
        .toList();
  }

  List<Map<String, dynamic>> _normalizeEntities(dynamic value) {
    return _listItems(value)
        .map((item) {
          final map = _asMap(item);
          if (map == null) {
            return {
              'name': _stringValue(item),
              'aliases': <String>[],
              'type': '',
              'relationshipToUser': '',
              'attitudeToUser': '',
              'knowledge': <String>[],
              'boundaries': <String>[],
              'cardOverrides': <String>[],
            };
          }
          return {
            'name': _stringValue(map['name']),
            'aliases': _stringList(map['aliases']),
            'type': _stringValue(map['type']),
            'relationshipToUser': _stringValue(map['relationshipToUser']),
            'attitudeToUser': _stringValue(map['attitudeToUser']),
            'knowledge': _stringList(map['knowledge']),
            'boundaries': _stringList(map['boundaries']),
            'cardOverrides': _stringList(map['cardOverrides']),
          };
        })
        .where((item) => (item['name'] as String).isNotEmpty)
        .toList();
  }

  List<Map<String, dynamic>> _normalizeArcState(dynamic value) {
    return _listItems(value)
        .map((item) {
          final map = _asMap(item);
          if (map == null) {
            final id = _stringValue(item);
            return {
              'id': id,
              'title': id,
              'status': 'seeded',
              'summary': '',
              'doNotReopen': false,
              'cardOverride': '',
              'entities': <String>[],
              'topics': <String>[],
            };
          }
          return {
            'id': _stringValue(map['id']),
            'title': _stringValue(map['title']),
            'status': _stringValue(map['status']).ifBlank('seeded'),
            'summary': _stringValue(map['summary']),
            'doNotReopen': _boolValue(map['doNotReopen']),
            'cardOverride': _stringValue(map['cardOverride']),
            'entities': _stringList(map['entities']),
            'topics': _stringList(map['topics']),
          };
        })
        .where((item) => (item['id'] as String).isNotEmpty)
        .toList();
  }

  List<Map<String, dynamic>> _normalizeKnowledgeFacts(dynamic value) {
    return _listItems(value).map((item) {
      final map = _asMap(item) ?? const <String, dynamic>{};
      return {
        'knowerKey': _stringValue(map['knowerKey']),
        'knowerName': _stringValue(map['knowerName']),
        'subjectKey': _stringValue(map['subjectKey']),
        'subjectName': _stringValue(map['subjectName']),
        'factClass': _stringValue(map['factClass']).ifBlank('knowledge'),
        'scopeKey': _stringValue(map['scopeKey']),
        'predicate': _stringValue(map['predicate']),
        'object': _stringValue(map['object']),
        'epistemicState': _stringValue(
          map['epistemicState'],
        ).ifBlank('observed'),
        'confidence': _doubleValue(map['confidence'], 0.5),
        'importance': _doubleValue(map['importance'], 0.5),
        'entities': _stringList(map['entities']),
        'topics': _stringList(map['topics']),
        'supersedesId': _nullableStringValue(map['supersedesId']),
      };
    }).toList();
  }

  List<Map<String, dynamic>> _normalizeOps(dynamic value) {
    return _listItems(value).map((item) {
      final map = _asMap(item);
      if (map == null) {
        return {
          'op': '',
          'key': '',
          'value': _stringValue(item),
          'evidence': '',
          'eventState': '',
        };
      }
      return {
        'op': _stringValue(map['op']),
        'key': _stringValue(map['key']),
        'value': _stringValue(map['value']),
        'evidence': _stringValue(map['evidence']),
        'eventState': _stringValue(map['eventState']),
      };
    }).toList();
  }

  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is! Map) return null;
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  List<dynamic> _listItems(dynamic value) {
    if (value is List) return value;
    if (value == null) return const [];
    return [value];
  }

  List<String> _stringList(dynamic value) {
    return _listItems(
      value,
    ).map(_stringValue).where((item) => item.trim().isNotEmpty).toList();
  }

  String _stringValue(dynamic value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    if (value is num || value is bool) return value.toString();
    if (value is List) {
      return value
          .map(_stringValue)
          .where((item) => item.isNotEmpty)
          .join('; ');
    }
    if (value is Map) return jsonEncode(value);
    return value.toString().trim();
  }

  double _doubleValue(dynamic value, double fallback) {
    if (value is num) return value.toDouble();
    return double.tryParse(_stringValue(value)) ?? fallback;
  }

  String? _nullableStringValue(dynamic value) {
    final normalized = _stringValue(value);
    return normalized.isEmpty ? null : normalized;
  }

  bool _boolValue(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.toLowerCase().trim() == 'true';
    return false;
  }

  // ── Validation ──────────────────────────────────────────────────────────────

  List<LedgerKnowledgeFact> _validateKnowledgeFacts(
    List<LedgerKnowledgeFact> facts,
  ) {
    final accepted = <LedgerKnowledgeFact>[];
    final seen = <String>{};
    for (final fact in facts) {
      final normalized = fact.copyWith(
        confidence: fact.confidence.clamp(0, 1).toDouble(),
        importance: fact.importance.clamp(0, 1).toDouble(),
      );
      final reason = _validateKnowledgeFact(normalized);
      if (reason != null) {
        debugPrint('[StudioLedger] rejected knowledge fact: $reason');
        continue;
      }
      final dedupeKey = [
        normalized.knowerKey,
        normalized.subjectKey,
        normalized.factClass,
        normalized.scopeKey,
        normalized.predicate,
        normalized.object,
        normalized.epistemicState,
      ].join('\u0000');
      if (seen.add(dedupeKey)) accepted.add(normalized);
    }
    return accepted;
  }

  String? _validateKnowledgeFact(LedgerKnowledgeFact fact) {
    if (fact.knowerKey.isEmpty || fact.subjectKey.isEmpty) {
      return 'missing knowerKey or subjectKey';
    }
    if (fact.predicate.isEmpty || fact.object.isEmpty) {
      return 'missing predicate or object';
    }
    if (fact.predicate.length > 120 || fact.scopeKey.length > 160) {
      return 'field exceeds length limit';
    }
    if (!CharacterKnowledgeFactClass.values.any(
      (value) => value.wireName == fact.factClass,
    )) {
      return 'unknown factClass "${fact.factClass}"';
    }
    if (!CharacterKnowledgeEpistemicState.values.any(
      (value) => value.wireName == fact.epistemicState,
    )) {
      return 'unknown epistemicState "${fact.epistemicState}"';
    }
    return null;
  }

  /// Returns a rejection reason string, or null when the op is valid.
  String? _validateOp(LedgerOp op) {
    // Unknown op code.
    if (!kAllowedOpCodes.contains(op.op)) {
      return 'unknown op code "${op.op}"';
    }

    // Unknown namespace.
    final hasValidNs = kAllowedNamespacePrefixes.any(
      (prefix) => op.key.startsWith(prefix),
    );
    if (!hasValidNs) {
      return 'unknown namespace in key "${op.key}"';
    }

    // Key must be non-empty and have a sub-key after the prefix.
    if (op.key.trim().isEmpty) {
      return 'empty key';
    }

    final keyReason = _validateCurrentStateKey(op.key);
    if (keyReason != null) return keyReason;

    // For set: value must not be empty and must remain a compact current value.
    if (op.op != 'delete' && op.value.trim().isEmpty) {
      return 'empty value for op "${op.op}"';
    }
    if (op.value.length > 1200) {
      return 'current-state value exceeds 1200 characters';
    }

    // Unknown event state.
    if (!kAllowedEventStates.contains(op.eventState)) {
      return 'unknown eventState "${op.eventState}"';
    }

    return null;
  }

  String? _validateCurrentStateKey(String key) {
    if (key.startsWith('npc:')) {
      final match = RegExp(r'^npc:([^.:][^.]*?)\.([a-z_]+)$').firstMatch(key);
      if (match == null) return 'malformed npc key "$key"';
      const fields = {
        'relationship_to_user',
        'attitude_to_user',
        'trust_to_user',
        'boundaries',
        'card_overrides',
        'location',
        'current_emotional_residue',
        'current_goal',
        'persistent_condition',
      };
      if (!fields.contains(match.group(2))) {
        return 'non-current or unknown npc field "${match.group(2)}"';
      }
    } else if (key.startsWith('relationship:')) {
      final match = RegExp(
        r'^relationship:([^.:][^:]*):([^.:][^.]*?)\.([a-z_]+)$',
      ).firstMatch(key);
      if (match == null) return 'malformed relationship key "$key"';
      const fields = {
        'trust',
        'status',
        'relationship',
        'attitude',
        'boundaries',
        'card_override',
      };
      if (!fields.contains(match.group(3))) {
        return 'non-current or unknown relationship field "${match.group(3)}"';
      }
    } else if (key.startsWith('arc:')) {
      if (!RegExp(
        r'^arc:([^.:][^.]*?)\.(status|title|summary|do_not_reopen|card_override)$',
      ).hasMatch(key)) {
        return 'malformed or unknown arc key "$key"';
      }
    } else if (key.startsWith('world:')) {
      if (!RegExp(
        r'^world:(location|time|date|active_threats|current_conditions)$',
      ).hasMatch(key)) {
        return 'unknown world key "$key"';
      }
    } else if (key.startsWith('scene.')) {
      if (!RegExp(
        r'^scene\.(present_entities|absent_backstory_entities|immediate_thread|active_tensions)$',
      ).hasMatch(key)) {
        return 'unknown scene key "$key"';
      }
    }
    return null;
  }
}

extension _LedgerStringFallback on String {
  String ifBlank(String fallback) => trim().isEmpty ? fallback : this;
}
