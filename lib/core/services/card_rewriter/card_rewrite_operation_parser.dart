import 'dart:convert';

import 'package:glaze_flutter/core/llm/json_repair.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

/// Why an untrusted writer-lane response was rejected. Every failure of
/// [CardRewriteOperationParser.parse] maps to exactly one of these reasons;
/// malformed model output never throws.
enum CardRewriteOperationParseRejection {
  /// No brace-delimited JSON payload could be extracted.
  noJsonPayload,

  /// The extracted payload did not decode as JSON (even after repair).
  invalidJson,

  /// The decoded JSON root is not an object.
  payloadNotObject,

  /// A key appeared outside the operation snapshot shape (top-level, patch,
  /// or transition). A patch-level `field` key lands here: it implies an
  /// operation spanning multiple fields.
  unknownKey,

  /// `field` was missing, not a string, not a known writable field, or not
  /// writable per [CardRewritePolicy].
  unknownField,

  /// `field` was a known writable field but not the requested target field —
  /// the writer lane rewrites exactly one field per operation.
  fieldMismatch,

  /// `patches` was missing or not a list.
  patchesNotList,

  /// `patches` was an empty list.
  emptyPatches,

  /// A patch element was not an object or lacked the required string members.
  malformedPatch,

  /// A patch anchor was the empty string.
  emptyAnchor,

  /// The provided `anchorSha256` did not match the recomputed anchor hash.
  staleAnchorHash,

  /// A patch or transition `scopeKey` failed [CardRewriteScope.tryParse].
  invalidScope,

  /// A replacement changed the exact multiset of `{{...}}` macro tokens from
  /// its anchored source fragment.
  macroTokensChanged,

  /// The transition was missing, not an object, or had malformed members.
  malformedTransition,

  /// `transition.chatSessionId` was present and non-null: only global
  /// transitions are writable.
  nonGlobalTransition,

  /// `transition.canonicalClaim` was missing or empty.
  missingCanonicalClaim,

  /// `transition.promotionDestination` was missing or empty.
  missingPromotionDestination,

  /// `transition.affectedTrackerKeys` was missing (an empty list is legal).
  missingAffectedTrackerKeys,

  /// A patch scope differed from the transition scope; apply requires all of
  /// an operation's patches to use the transition's scope.
  scopeMismatch,
}

/// Typed outcome of screening one untrusted writer-lane response.
final class CardRewriteOperationParseResult {
  const CardRewriteOperationParseResult._(
    this.snapshot,
    this.rejection,
    this.detail,
  );

  const CardRewriteOperationParseResult.success(
    CardRewriteOperationSnapshot snapshot,
  ) : this._(snapshot, null, null);

  const CardRewriteOperationParseResult.failure(
    CardRewriteOperationParseRejection rejection, [
    String? detail,
  ]) : this._(null, rejection, detail);

  /// The validated snapshot; non-null iff [isSuccess].
  final CardRewriteOperationSnapshot? snapshot;

  /// The rejection reason; non-null iff `!isSuccess`.
  final CardRewriteOperationParseRejection? rejection;

  /// Optional human-readable context (key names, wire names) for diagnostics.
  final String? detail;

  bool get isSuccess => snapshot != null;
}

/// Strictly parses one untrusted LLM response into a typed
/// [CardRewriteOperationSnapshot]. Pure: no DB, no UI, no network.
///
/// Extraction tolerates surrounding prose and markdown fences via
/// [extractJsonObject] + [repairJson] from `core/llm/json_repair.dart`, then
/// screens the decoded payload against the writer-lane contract:
///
/// - exactly one JSON object, no unknown keys anywhere in the shape;
/// - `field` is a writable [CardRewriteField] equal to [expectedField];
/// - `patches` is a non-empty list of single-field, non-empty-anchor patches
///   whose `scopeKey` parses per [CardRewriteScope], whose `anchorSha256`
///   matches the RECOMPUTED [CardCanonicalizer.scalarSha256] of the anchor;
/// - the transition is global (`chatSessionId` absent or null) with
///   non-empty `id`/`canonicalClaim`/`promotionDestination`, a valid scope
///   shared by every patch, and a present `affectedTrackerKeys` list whose
///   entries (and optional `factIds` entries) are non-empty strings.
abstract final class CardRewriteOperationParser {
  static const Set<String> _operationKeys = {'field', 'patches', 'transition'};
  static const Set<String> _patchKeys = {
    'scopeKey',
    'anchor',
    'anchorSha256',
    'value',
  };
  static const Set<String> _transitionKeys = {
    'id',
    'scopeKey',
    'canonicalClaim',
    'promotionDestination',
    'affectedTrackerKeys',
    'factIds',
    'chatSessionId',
  };

  /// Parses the one-call automated evolution response. The outer batch may
  /// omit unchanged fields, but each supplied operation is screened by the
  /// same single-field contract used by manual rewrites.
  static List<CardRewriteOperationSnapshot>? parseEvolutionBatch(
    String output, {
    Set<CardRewriteField> allowedFields = CardRewritePolicy.evolutionFields,
  }) {
    return _parseEvolutionBatch(
      output,
      allowedFields: allowedFields,
    ).operations;
  }

  /// Describes why a one-call card evolution response could not be screened.
  /// The text is deliberately bounded for UI diagnostics and is never persisted.
  static String? explainEvolutionBatchFailure(
    String output, {
    Set<CardRewriteField> allowedFields = CardRewritePolicy.evolutionFields,
  }) => _parseEvolutionBatch(output, allowedFields: allowedFields).detail;

  static _EvolutionBatchParse _parseEvolutionBatch(
    String output, {
    required Set<CardRewriteField> allowedFields,
  }) {
    final raw = extractJsonObject(output);
    if (raw == null) {
      return const _EvolutionBatchParse.failure('no JSON object was found');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(repairJson(raw));
    } catch (_) {
      return const _EvolutionBatchParse.failure('JSON could not be decoded');
    }
    if (decoded is! Map ||
        decoded.length != 1 ||
        !decoded.containsKey('operations') ||
        decoded['operations'] is! List) {
      return const _EvolutionBatchParse.failure(
        'expected exactly {"operations": [...]}',
      );
    }
    final operations = decoded['operations'] as List;
    final result = <CardRewriteOperationSnapshot>[];
    final fields = <CardRewriteField>{};
    for (final rawOperation in operations) {
      if (rawOperation is! Map || rawOperation['field'] is! String) {
        return const _EvolutionBatchParse.failure(
          'each operation requires a string field',
        );
      }
      final field = _fieldFromWireName(rawOperation['field'] as String);
      if (field == null ||
          !allowedFields.contains(field) ||
          !fields.add(field)) {
        return const _EvolutionBatchParse.failure(
          'field is unsupported or repeated',
        );
      }
      final parsed = parse(
        jsonEncode(rawOperation),
        expectedField: field,
        allowEmptyAnchor: false,
      );
      if (parsed.snapshot == null) {
        final reason = parsed.rejection?.name ?? 'unknown rejection';
        return _EvolutionBatchParse.failure(
          '${field.wireName}: $reason${parsed.detail == null ? '' : ' (${parsed.detail})'}',
        );
      }
      result.add(parsed.snapshot!);
    }
    return _EvolutionBatchParse.success(List.unmodifiable(result));
  }

  /// Parses the separate writer lane for session-local lorebook patches.
  ///
  /// An LLM cannot compute SHA-256 digests, so the model contract no longer
  /// asks for `anchorSha256`; any model-supplied value is overwritten with
  /// the recomputed hash before structural validation. The apply layer
  /// remains the final authority and re-validates anchors against live
  /// content.
  static List<LorebookRewriteOperationSnapshot>? parseLorebookEvolutionBatch(
    String output,
  ) {
    final raw = extractJsonObject(output);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(repairJson(raw));
      if (decoded is! Map ||
          decoded.length != 1 ||
          decoded['operations'] is! List) {
        return null;
      }
      final result = <LorebookRewriteOperationSnapshot>[];
      final targets = <String>{};
      for (final rawOperation in decoded['operations'] as List) {
        if (rawOperation is! Map) return null;
        final normalized = <String, Object?>{
          'target': 'lorebook',
          ...Map<String, Object?>.from(rawOperation),
        };
        final patchesValue = normalized['patches'];
        if (patchesValue is! List) return null;
        final patches = <Map<String, Object?>>[];
        for (final rawPatch in patchesValue) {
          if (rawPatch is! Map) return null;
          final patch = Map<String, Object?>.from(rawPatch);
          final anchor = patch['anchor'];
          if (anchor is! String) return null;
          patch['anchorSha256'] = CardCanonicalizer.scalarSha256(anchor);
          patches.add(patch);
        }
        normalized['patches'] = patches;
        final snapshot = RewriteOperationSnapshotCodec.tryDecode(normalized);
        if (snapshot is! LorebookRewriteOperationSnapshot ||
            !targets.add('${snapshot.lorebookId}\u0000${snapshot.entryId}')) {
          return null;
        }
        result.add(snapshot);
      }
      return List.unmodifiable(result);
    } catch (_) {
      return null;
    }
  }

  static CardRewriteOperationParseResult parse(
    String output, {
    required CardRewriteField expectedField,
    bool allowEmptyAnchor = false,
  }) {
    final raw = extractJsonObject(output);
    if (raw == null) {
      return const CardRewriteOperationParseResult.failure(
        CardRewriteOperationParseRejection.noJsonPayload,
        'no brace-delimited JSON object found',
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(repairJson(raw));
    } catch (_) {
      return const CardRewriteOperationParseResult.failure(
        CardRewriteOperationParseRejection.invalidJson,
        'extracted payload is not valid JSON',
      );
    }
    if (decoded is! Map) {
      return const CardRewriteOperationParseResult.failure(
        CardRewriteOperationParseRejection.payloadNotObject,
      );
    }
    final unknownOperationKey = _firstUnknownKey(decoded, _operationKeys);
    if (unknownOperationKey != null) {
      return CardRewriteOperationParseResult.failure(
        CardRewriteOperationParseRejection.unknownKey,
        'unexpected operation key "$unknownOperationKey"',
      );
    }

    final fieldValue = decoded['field'];
    if (fieldValue is! String) {
      return const CardRewriteOperationParseResult.failure(
        CardRewriteOperationParseRejection.unknownField,
        '"field" must be a string',
      );
    }
    CardRewriteField? field;
    for (final candidate in CardRewriteField.values) {
      if (candidate.wireName == fieldValue) field = candidate;
    }
    if (field == null || !CardRewritePolicy.isWritable(field)) {
      return CardRewriteOperationParseResult.failure(
        CardRewriteOperationParseRejection.unknownField,
        'field "$fieldValue" is not writable',
      );
    }
    if (field != expectedField) {
      return CardRewriteOperationParseResult.failure(
        CardRewriteOperationParseRejection.fieldMismatch,
        'expected "${expectedField.wireName}", got "${field.wireName}"',
      );
    }
    final patchesValue = decoded['patches'];
    if (patchesValue is! List) {
      return const CardRewriteOperationParseResult.failure(
        CardRewriteOperationParseRejection.patchesNotList,
      );
    }
    if (patchesValue.isEmpty) {
      return const CardRewriteOperationParseResult.failure(
        CardRewriteOperationParseRejection.emptyPatches,
      );
    }
    final patches = <AnchoredScalarPatch>[];
    for (final rawPatch in patchesValue) {
      if (rawPatch is! Map) {
        return const CardRewriteOperationParseResult.failure(
          CardRewriteOperationParseRejection.malformedPatch,
          'patch must be an object',
        );
      }
      final unknownPatchKey = _firstUnknownKey(rawPatch, _patchKeys);
      if (unknownPatchKey != null) {
        return CardRewriteOperationParseResult.failure(
          CardRewriteOperationParseRejection.unknownKey,
          'unexpected patch key "$unknownPatchKey"',
        );
      }
      final scopeKey = rawPatch['scopeKey'];
      final anchor = rawPatch['anchor'];
      final anchorSha256 = rawPatch['anchorSha256'];
      final value = rawPatch['value'];
      if (scopeKey is! String ||
          anchor is! String ||
          anchorSha256 != null && anchorSha256 is! String ||
          value is! String) {
        return const CardRewriteOperationParseResult.failure(
          CardRewriteOperationParseRejection.malformedPatch,
          'patch members scopeKey, anchor, value must be strings',
        );
      }
      final canonicalScopeKey = _canonicalScopeKey(scopeKey);
      if (canonicalScopeKey == null) {
        return CardRewriteOperationParseResult.failure(
          CardRewriteOperationParseRejection.invalidScope,
          'unparsable patch scopeKey "$scopeKey"',
        );
      }
      if (anchor.isEmpty && !allowEmptyAnchor) {
        return const CardRewriteOperationParseResult.failure(
          CardRewriteOperationParseRejection.emptyAnchor,
        );
      }
      // The model cannot compute SHA-256 digests, so the instruction no
      // longer asks for anchorSha256: any supplied value is advisory and
      // the hash is always recomputed here. Exact live-anchor checks on
      // the apply side remain the real safety boundary.
      final computedAnchorHash = CardCanonicalizer.scalarSha256(anchor);
      if (!AnchoredScalarPatchValidator.preservesMacroTokens(anchor, value)) {
        return const CardRewriteOperationParseResult.failure(
          CardRewriteOperationParseRejection.macroTokensChanged,
          'replacement must preserve the anchor macro-token multiset exactly',
        );
      }
      patches.add(
        AnchoredScalarPatch(
          scopeKey: canonicalScopeKey,
          field: field,
          anchor: anchor,
          anchorSha256: computedAnchorHash,
          value: value,
        ),
      );
    }

    final transitionOutcome = _parseTransition(decoded['transition']);
    final transitionFailure = transitionOutcome.failure;
    if (transitionFailure != null) return transitionFailure;
    final transition = transitionOutcome.value!;
    final transitionScopeKey = transition.scopeKey;
    if (patches.any((patch) => patch.scopeKey != transitionScopeKey)) {
      return CardRewriteOperationParseResult.failure(
        CardRewriteOperationParseRejection.scopeMismatch,
        'every patch scopeKey must equal "$transitionScopeKey"',
      );
    }

    return CardRewriteOperationParseResult.success(
      CardRewriteOperationSnapshot(
        field: field,
        patches: List<AnchoredScalarPatch>.unmodifiable(patches),
        transition: transition,
      ),
    );
  }

  static ({
    CardRewriteTransitionSnapshot? value,
    CardRewriteOperationParseResult? failure,
  })
  _parseTransition(Object? json) {
    CardRewriteOperationParseResult fail(
      CardRewriteOperationParseRejection rejection, [
      String? detail,
    ]) => CardRewriteOperationParseResult.failure(rejection, detail);

    if (json is! Map) {
      return (
        value: null,
        failure: fail(
          CardRewriteOperationParseRejection.malformedTransition,
          '"transition" must be an object',
        ),
      );
    }
    final unknownTransitionKey = _firstUnknownKey(json, _transitionKeys);
    if (unknownTransitionKey != null) {
      return (
        value: null,
        failure: fail(
          CardRewriteOperationParseRejection.unknownKey,
          'unexpected transition key "$unknownTransitionKey"',
        ),
      );
    }
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      return (
        value: null,
        failure: fail(
          CardRewriteOperationParseRejection.malformedTransition,
          '"transition.id" must be a non-empty string',
        ),
      );
    }
    final scopeKey = json['scopeKey'];
    if (scopeKey is! String) {
      return (
        value: null,
        failure: fail(
          CardRewriteOperationParseRejection.malformedTransition,
          '"transition.scopeKey" must be a string',
        ),
      );
    }
    final canonicalScopeKey = _canonicalScopeKey(scopeKey);
    if (canonicalScopeKey == null) {
      return (
        value: null,
        failure: fail(
          CardRewriteOperationParseRejection.invalidScope,
          'unparsable transition scopeKey "$scopeKey"',
        ),
      );
    }
    final canonicalClaim = json['canonicalClaim'];
    if (canonicalClaim is! String || canonicalClaim.isEmpty) {
      return (
        value: null,
        failure: fail(CardRewriteOperationParseRejection.missingCanonicalClaim),
      );
    }
    final promotionDestination = json['promotionDestination'];
    if (promotionDestination is! String || promotionDestination.isEmpty) {
      return (
        value: null,
        failure: fail(
          CardRewriteOperationParseRejection.missingPromotionDestination,
        ),
      );
    }
    final affectedTrackerKeysValue = json['affectedTrackerKeys'];
    if (affectedTrackerKeysValue == null) {
      return (
        value: null,
        failure: fail(
          CardRewriteOperationParseRejection.missingAffectedTrackerKeys,
        ),
      );
    }
    final affectedTrackerKeys = _parseStringList(affectedTrackerKeysValue);
    if (affectedTrackerKeys == null) {
      return (
        value: null,
        failure: fail(
          CardRewriteOperationParseRejection.malformedTransition,
          '"transition.affectedTrackerKeys" must be a list of non-empty strings',
        ),
      );
    }
    final factIdsValue = json['factIds'];
    final factIds = factIdsValue == null
        ? const <String>[]
        : _parseStringList(factIdsValue);
    if (factIds == null) {
      return (
        value: null,
        failure: fail(
          CardRewriteOperationParseRejection.malformedTransition,
          '"transition.factIds" must be a list of non-empty strings',
        ),
      );
    }
    final chatSessionId = json['chatSessionId'];
    if (chatSessionId != null) {
      return (
        value: null,
        failure: fail(
          CardRewriteOperationParseRejection.nonGlobalTransition,
          '"transition.chatSessionId" must be absent or null',
        ),
      );
    }
    return (
      value: CardRewriteTransitionSnapshot(
        id: id,
        scopeKey: canonicalScopeKey,
        canonicalClaim: canonicalClaim,
        promotionDestination: promotionDestination,
        affectedTrackerKeys: List<String>.unmodifiable(affectedTrackerKeys),
        factIds: List<String>.unmodifiable(factIds),
      ),
      failure: null,
    );
  }

  /// Returns the list's strings, or null when it is not a list or contains a
  /// non-string or empty entry (empty entries can never satisfy apply-side
  /// tracker/fact checks).
  static List<String>? _parseStringList(Object? value) {
    if (value is! List) return null;
    final result = <String>[];
    for (final element in value) {
      if (element is! String || element.isEmpty) return null;
      result.add(element);
    }
    return result;
  }

  static String? _firstUnknownKey(
    Map<dynamic, dynamic> json,
    Set<String> allowed,
  ) {
    for (final key in json.keys) {
      if (key is! String || !allowed.contains(key)) return '$key';
    }
    return null;
  }

  static CardRewriteField? _fieldFromWireName(String value) {
    for (final field in CardRewriteField.values) {
      if (field.wireName == value) return field;
    }
    return null;
  }

  /// Scope identities are exact RP-language Ledger keys. Case folding or
  /// transliteration would silently retarget a different identity.
  static String? _canonicalScopeKey(String value) {
    return CardRewriteScope.tryParse(value)?.key;
  }
}

final class _EvolutionBatchParse {
  const _EvolutionBatchParse.success(this.operations) : detail = null;
  const _EvolutionBatchParse.failure(this.detail) : operations = null;

  final List<CardRewriteOperationSnapshot>? operations;
  final String? detail;
}
