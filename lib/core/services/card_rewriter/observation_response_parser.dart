import 'dart:convert';

final class ObservationResponseParser {
  const ObservationResponseParser();

  List<ParsedObservationAction>? parse(String output) {
    try {
      final cleaned = output
          .replaceAll(RegExp(r'^```(?:json)?\s*'), '')
          .replaceAll(RegExp(r'\s*```$'), '')
          .trim();
      final decoded = jsonDecode(cleaned);
      if (decoded is! Map) return null;
      final observations = decoded['observations'];
      if (observations is! List) return null;
      final result = <ParsedObservationAction>[];
      final scopes = <String>{};
      for (final raw in observations) {
        if (raw is! Map) return null;
        final action = raw['action'];
        final scopeKey = raw['scopeKey'];
        final observedChange = raw['observedChange'];
        final confidence = raw['confidence'];
        final retrievalKeysRaw = raw['retrievalKeys'];
        final targetKind = raw['targetKind'];
        if (action is! String ||
            !const {
              'confirm',
              'new',
              'no_evidence',
              'contradict',
            }.contains(action) ||
            scopeKey is! String ||
            scopeKey.isEmpty ||
            !scopes.add(scopeKey) ||
            (action == 'new' &&
                (observedChange is! String || observedChange.isEmpty)) ||
            (action != 'no_evidence' &&
                (retrievalKeysRaw is! List ||
                    retrievalKeysRaw.isEmpty ||
                    retrievalKeysRaw.any(
                      (value) => value is! String || value.isEmpty,
                    ))) ||
            (action != 'no_evidence' &&
                !const {
                  'main_character_card',
                  'injected_lorebook_entry',
                }.contains(targetKind))) {
          return null;
        }
        final conf = confidence is num ? confidence.toDouble() : 0.5;
        final clampedConf = conf < 0.0
            ? 0.0
            : conf > 1.0
            ? 1.0
            : conf;
        final evidenceRaw = raw['evidenceMessageIds'];
        if (action != 'no_evidence' &&
            (evidenceRaw is! List ||
                evidenceRaw.any((item) => item is! String))) {
          return null;
        }
        final evidence = <String>[];
        for (final item
            in (evidenceRaw is List
                ? evidenceRaw.cast<String>()
                : const <String>[])) {
          if (item.isNotEmpty && !evidence.contains(item)) evidence.add(item);
        }
        if (action != 'no_evidence' && evidence.isEmpty) return null;
        result.add(
          ParsedObservationAction(
            action: action,
            scopeKey: scopeKey,
            observedChange: observedChange is String ? observedChange : '',
            canonicalClaim: raw['canonicalClaim'] is String
                ? raw['canonicalClaim'] as String
                : null,
            evidenceMessageIds: evidence,
            retrievalKeys: retrievalKeysRaw is List
                ? retrievalKeysRaw.cast<String>().toSet().toList()
                : const [],
            targetKind: targetKind is String ? targetKind : null,
            cardFieldPath: raw['cardFieldPath'] is String
                ? raw['cardFieldPath'] as String
                : null,
            lorebookEntryId: raw['lorebookEntryId'] is String
                ? raw['lorebookEntryId'] as String
                : null,
            confidence: clampedConf,
          ),
        );
      }
      return result;
    } catch (_) {
      return null;
    }
  }
}

final class ParsedObservationAction {
  const ParsedObservationAction({
    required this.action,
    required this.scopeKey,
    required this.observedChange,
    required this.canonicalClaim,
    required this.evidenceMessageIds,
    required this.retrievalKeys,
    required this.targetKind,
    required this.cardFieldPath,
    required this.lorebookEntryId,
    required this.confidence,
  });

  final String action;
  final String scopeKey;
  final String observedChange;
  final String? canonicalClaim;
  final List<String> evidenceMessageIds;
  final List<String> retrievalKeys;
  final String? targetKind;
  final String? cardFieldPath;
  final String? lorebookEntryId;
  final double confidence;
}
