/// Pure contracts used by a future card-rewriting workflow.
///
/// This library deliberately has no persistence, UI, or model-generation
/// dependencies.  It defines the stable card snapshot and validates proposed
/// scalar changes against that snapshot.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_prompt_sanitizer.dart';

/// Produces stable durable and model-facing representations of a [Character].
///
/// Nullable text fields are intentionally normalized to an empty string: a
/// missing card field and an explicitly empty card field have the same prompt
/// meaning. Lists retain their order because greeting order is meaningful.
abstract final class CardCanonicalizer {
  static String serialize(Character character) =>
      jsonEncode(snapshot(character));

  static String sha256(Character character) =>
      crypto.sha256.convert(utf8.encode(serialize(character))).toString();

  static Map<String, Object?> snapshot(Character character) => _stableMap({
    'alternateGreetings': character.alternateGreetings.toList(growable: false),
    'creator': _text(character.creator),
    'creatorNotes': _text(character.creatorNotes),
    'depthPrompt': character.depthPrompt,
    'depthPromptDepth': character.depthPromptDepth,
    'depthPromptRole': character.depthPromptRole,
    'description': _text(character.description),
    'extensions': _normalizeJson(character.extensions),
    'firstMes': _text(character.firstMes),
    'macroName': _text(character.macroName),
    'mesExample': _text(character.mesExample),
    'name': character.name,
    'personality': _text(character.personality),
    'postHistoryInstructions': _text(character.postHistoryInstructions),
    'scenario': _text(character.scenario),
    'systemPrompt': _text(character.systemPrompt),
    'tags': character.tags.toList(growable: false),
    'world': _text(character.world),
  });

  /// Character data that may be included in an LLM prompt.
  ///
  /// Creator notes are user-facing metadata and are deliberately absent. Keep
  /// this as an allowlist so newly added card metadata does not become model
  /// context by accident.
  static Map<String, Object?> promptSnapshot(Character character) {
    final safe = sanitizeCharacterForPrompt(character);
    return _stableMap({
      'alternateGreetings': safe.alternateGreetings.toList(growable: false),
      'creator': _text(safe.creator),
      'depthPrompt': safe.depthPrompt,
      'depthPromptDepth': safe.depthPromptDepth,
      'depthPromptRole': safe.depthPromptRole,
      'description': _text(safe.description),
      'extensions': _normalizeJson(safe.extensions),
      'firstMes': _text(safe.firstMes),
      'macroName': _text(safe.macroName),
      'mesExample': _text(safe.mesExample),
      'name': safe.name,
      'personality': _text(safe.personality),
      'postHistoryInstructions': _text(safe.postHistoryInstructions),
      'scenario': _text(safe.scenario),
      'systemPrompt': _text(safe.systemPrompt),
      'tags': safe.tags.toList(growable: false),
      'world': _text(safe.world),
    });
  }

  static String scalarSha256(String? value) =>
      crypto.sha256.convert(utf8.encode(_text(value))).toString();

  static String _text(String? value) => value ?? '';

  static Object? _normalizeJson(Object? value) {
    if (value == null || value is String || value is bool || value is num) {
      return value;
    }
    if (value is List<Object?>) {
      return List<Object?>.unmodifiable(value.map(_normalizeJson));
    }
    if (value is Map<Object?, Object?>) {
      final normalized = <String, Object?>{};
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw ArgumentError.value(
            entry.key,
            'extensions key',
            'must be a String',
          );
        }
        normalized[entry.key! as String] = _normalizeJson(entry.value);
      }
      return _stableMap(normalized);
    }
    throw ArgumentError.value(
      value,
      'extensions value',
      'must be JSON-compatible',
    );
  }

  static Map<String, Object?> _stableMap(Map<String, Object?> value) {
    final sortedKeys = value.keys.toList()..sort();
    return Map<String, Object?>.unmodifiable({
      for (final key in sortedKeys) key: value[key],
    });
  }
}

/// The only character fields initially writable by Card Rewriter.
enum CardRewriteField {
  description,
  personality,
  scenario,
  systemPrompt,
  postHistoryInstructions,
  creatorNotes;

  String get wireName => name;
}

/// Explicit per-field limits, measured in Unicode code units.
abstract final class CardRewritePolicy {
  static const Set<CardRewriteField> evolutionFields = {
    CardRewriteField.description,
    CardRewriteField.personality,
    CardRewriteField.scenario,
  };
  static const Set<CardRewriteField> writableFields = {
    CardRewriteField.description,
    CardRewriteField.personality,
    CardRewriteField.scenario,
    CardRewriteField.systemPrompt,
    CardRewriteField.postHistoryInstructions,
    CardRewriteField.creatorNotes,
  };
  static const Set<CardRewriteField> modelWritableFields = {
    CardRewriteField.description,
    CardRewriteField.personality,
    CardRewriteField.scenario,
    CardRewriteField.systemPrompt,
    CardRewriteField.postHistoryInstructions,
  };

  static bool isWritable(CardRewriteField field) =>
      writableFields.contains(field);

  static bool isModelWritable(CardRewriteField field) =>
      modelWritableFields.contains(field);

  static Set<CardRewriteField> nonEmptyEvolutionFields(Character character) => {
    if (character.description?.isNotEmpty == true) CardRewriteField.description,
    if (character.personality?.isNotEmpty == true) CardRewriteField.personality,
    if (character.scenario?.isNotEmpty == true) CardRewriteField.scenario,
  };
}

/// The semantic family addressed by a rewrite request.
enum CardRewriteScopeKind { npc, relationship, arc, world, scene }

/// A validated scope key. Valid keys are limited to `npc:`, `relationship:`,
/// `arc:`, `world:`, and dotted `scene.` keys.
final class CardRewriteScope {
  const CardRewriteScope._(this.kind, this.subject, this.key);

  final CardRewriteScopeKind kind;
  final String subject;
  final String key;

  static CardRewriteScope? tryParse(String key) {
    for (final entry in const <String, CardRewriteScopeKind>{
      'npc:': CardRewriteScopeKind.npc,
      'relationship:': CardRewriteScopeKind.relationship,
      'arc:': CardRewriteScopeKind.arc,
      'world:': CardRewriteScopeKind.world,
    }.entries) {
      if (key.startsWith(entry.key)) {
        final subject = key.substring(entry.key.length);
        return _safeIdentity(
              subject,
              allowDots: false,
              allowColons: entry.value == CardRewriteScopeKind.relationship,
            )
            ? CardRewriteScope._(entry.value, subject, key)
            : null;
      }
    }
    if (!key.startsWith('scene.')) return null;
    final subject = key.substring('scene.'.length);
    return _safeIdentity(
          subject,
          allowDots: true,
          requireNonEmptySegments: true,
        )
        ? CardRewriteScope._(CardRewriteScopeKind.scene, subject, key)
        : null;
  }

  static bool _safeIdentity(
    String value, {
    required bool allowDots,
    bool allowColons = false,
    bool requireNonEmptySegments = false,
  }) {
    if (value.isEmpty ||
        value.trim() != value ||
        value.contains(RegExp(r'\s'))) {
      return false;
    }
    if (!allowColons && value.contains(':')) return false;
    if (allowColons &&
        (value.split(':').length != 2 ||
            value.split(':').any((part) => part.isEmpty))) {
      return false;
    }
    if (requireNonEmptySegments &&
        value.split('.').any((part) => part.isEmpty)) {
      return false;
    }
    for (var index = 0; index < value.codeUnits.length; index++) {
      final unit = value.codeUnitAt(index);
      if (unit < 0x20 ||
          unit == 0x7f ||
          (unit >= 0x202a && unit <= 0x202e) ||
          (unit >= 0x2066 && unit <= 0x2069)) {
        return false;
      }
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++index >= value.codeUnits.length) return false;
        final low = value.codeUnitAt(index);
        if (low < 0xdc00 || low > 0xdfff) return false;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return false;
      }
    }
    return allowDots || !value.contains('.');
  }
}

/// An immutable requested replacement for one writable scalar field.
final class AnchoredScalarPatch {
  const AnchoredScalarPatch({
    required this.scopeKey,
    required this.field,
    required this.anchor,
    required this.anchorSha256,
    required this.value,
  });

  final String scopeKey;
  final CardRewriteField field;

  /// The literal, exactly-once fragment to replace in the current field.
  final String anchor;
  final String anchorSha256;
  final String value;
}

enum CardPatchViolation {
  invalidScope,
  duplicateAnchor,
  staleAnchor,
  ambiguousAnchor,
  incompleteSet,
  macroTokensChanged,
}

/// Result of validating a patch batch. The validator never applies patches.
final class CardPatchValidation {
  const CardPatchValidation._(this.violations);

  final List<CardPatchViolation> violations;
  bool get isValid => violations.isEmpty;
}

/// Validates and simulates exactly-once anchored scalar replacements.
abstract final class AnchoredScalarPatchValidator {
  static final RegExp _macroToken = RegExp(r'\{\{[^}]*\}\}');

  /// Macro tokens in an anchored fragment are executable card syntax, not
  /// prose. A rewrite must preserve their exact byte-level multiset.
  static bool preservesMacroTokens(String anchor, String value) {
    List<String> tokens(String text) =>
        _macroToken.allMatches(text).map((match) => match.group(0)!).toList()
          ..sort();
    final anchorTokens = tokens(anchor);
    final valueTokens = tokens(value);
    if (anchorTokens.length != valueTokens.length) return false;
    for (var index = 0; index < anchorTokens.length; index++) {
      if (anchorTokens[index] != valueTokens[index]) return false;
    }
    return true;
  }

  static CardPatchValidation validate({
    required Iterable<AnchoredScalarPatch> patches,
    required Map<CardRewriteField, String?> currentCardValues,
    Iterable<CardRewriteField>? requiredFields,
  }) {
    final violations = <CardPatchViolation>[];
    final seenTargets = <String>{};
    final patchList = patches.toList(growable: false);
    final projected = <CardRewriteField, String>{
      for (final field in CardRewriteField.values)
        field: currentCardValues[field] ?? '',
    };

    for (final patch in patchList) {
      if (!preservesMacroTokens(patch.anchor, patch.value)) {
        violations.add(CardPatchViolation.macroTokensChanged);
      }
      if (CardRewriteScope.tryParse(patch.scopeKey) == null) {
        violations.add(CardPatchViolation.invalidScope);
      }
      final target = '${patch.field.wireName}\u0000${patch.anchorSha256}';
      if (!seenTargets.add(target)) {
        violations.add(CardPatchViolation.duplicateAnchor);
      }
      if (CardCanonicalizer.scalarSha256(patch.anchor) != patch.anchorSha256) {
        violations.add(CardPatchViolation.staleAnchor);
        continue;
      }
      final current = projected[patch.field]!;
      final occurrences = _occurrences(current, patch.anchor);
      if (occurrences != 1) {
        violations.add(
          occurrences == 0
              ? CardPatchViolation.staleAnchor
              : CardPatchViolation.ambiguousAnchor,
        );
        continue;
      }
      projected[patch.field] = current.replaceFirst(patch.anchor, patch.value);
    }
    final required = requiredFields?.toSet();
    final seenFields = {for (final patch in patchList) patch.field};
    if (required != null && !seenFields.containsAll(required)) {
      violations.add(CardPatchViolation.incompleteSet);
    }
    return CardPatchValidation._(List.unmodifiable(violations));
  }

  static int _occurrences(String value, String anchor) {
    // An empty card field has exactly one unambiguous insertion point. This is
    // needed to let a reviewable rewrite initialize an otherwise blank field.
    if (anchor.isEmpty) return value.isEmpty ? 1 : 0;
    var count = 0;
    var from = 0;
    while (true) {
      final index = value.indexOf(anchor, from);
      if (index == -1) return count;
      count++;
      from = index + anchor.length;
    }
  }
}

/// An immutable canon-side transition descriptor carried by one rewrite
/// operation snapshot. A `null` [chatSessionId] marks a global transition;
/// session-scoped transitions are not writable by this workflow.
final class CardRewriteTransitionSnapshot {
  const CardRewriteTransitionSnapshot({
    required this.id,
    required this.scopeKey,
    required this.canonicalClaim,
    required this.promotionDestination,
    required this.affectedTrackerKeys,
    this.factIds = const [],
    this.chatSessionId,
  });

  final String id;
  final String scopeKey;
  final String canonicalClaim;
  final String promotionDestination;
  final List<String> affectedTrackerKeys;
  final List<String> factIds;
  final String? chatSessionId;
}

/// An immutable, fully-typed rewrite operation: anchored patches for exactly
/// one writable [field] plus the canon transition they promote.
sealed class RewriteOperationSnapshot {
  const RewriteOperationSnapshot();
}

final class CardRewriteOperationSnapshot extends RewriteOperationSnapshot {
  const CardRewriteOperationSnapshot({
    required this.field,
    required this.patches,
    required this.transition,
  });

  final CardRewriteField field;
  final List<AnchoredScalarPatch> patches;
  final CardRewriteTransitionSnapshot transition;
}

/// A session-local, anchored replacement for one lorebook entry. The source
/// book is never changed: apply writes only the current session's overlay.
final class LorebookAnchoredPatch {
  const LorebookAnchoredPatch({
    required this.anchor,
    required this.anchorSha256,
    required this.value,
  });

  final String anchor;
  final String anchorSha256;
  final String value;
}

final class LorebookRewriteOperationSnapshot extends RewriteOperationSnapshot {
  const LorebookRewriteOperationSnapshot({
    required this.lorebookId,
    required this.entryId,
    required this.baseContent,
    required this.expectedContentHash,
    required this.patches,
  });

  final String lorebookId;
  final String entryId;

  /// Immutable source content from the exact injected-entry manifest.
  final String baseContent;
  final String expectedContentHash;
  final List<LorebookAnchoredPatch> patches;
}

/// Codec for every durable review operation. Card snapshots deliberately retain
/// their legacy untagged shape so existing manual jobs remain readable.
abstract final class RewriteOperationSnapshotCodec {
  static String encode(RewriteOperationSnapshot snapshot) => switch (snapshot) {
    CardRewriteOperationSnapshot card =>
      ManualRewriteOperationSnapshotCodec.encode(card),
    LorebookRewriteOperationSnapshot lore => jsonEncode({
      'target': 'lorebook',
      'lorebookId': lore.lorebookId,
      'entryId': lore.entryId,
      'baseContent': lore.baseContent,
      'expectedContentHash': lore.expectedContentHash,
      'patches': [
        for (final patch in lore.patches)
          {
            'anchor': patch.anchor,
            'anchorSha256': patch.anchorSha256,
            'value': patch.value,
          },
      ],
    }),
  };

  static RewriteOperationSnapshot? tryDecode(Object? json) {
    if (json is! Map) return null;
    if (json['target'] != 'lorebook') {
      return ManualRewriteOperationSnapshotCodec.tryDecode(json);
    }
    if (json.length != 6 ||
        json['lorebookId'] is! String ||
        json['entryId'] is! String ||
        json['baseContent'] is! String ||
        json['expectedContentHash'] is! String ||
        json['patches'] is! List) {
      return null;
    }
    final lorebookId = json['lorebookId'] as String;
    final entryId = json['entryId'] as String;
    final baseContent = json['baseContent'] as String;
    final expectedContentHash = json['expectedContentHash'] as String;
    final rawPatches = json['patches'] as List;
    if (lorebookId.isEmpty ||
        entryId.isEmpty ||
        rawPatches.isEmpty ||
        expectedContentHash.isEmpty) {
      return null;
    }
    final patches = <LorebookAnchoredPatch>[];
    for (final raw in rawPatches) {
      if (raw is! Map ||
          raw.length != 3 ||
          raw['anchor'] is! String ||
          raw['anchorSha256'] is! String ||
          raw['value'] is! String) {
        return null;
      }
      final anchor = raw['anchor'] as String;
      final anchorSha256 = raw['anchorSha256'] as String;
      final value = raw['value'] as String;
      if (CardCanonicalizer.scalarSha256(anchor) != anchorSha256 ||
          !AnchoredScalarPatchValidator.preservesMacroTokens(anchor, value)) {
        return null;
      }
      patches.add(
        LorebookAnchoredPatch(
          anchor: anchor,
          anchorSha256: anchorSha256,
          value: value,
        ),
      );
    }
    return LorebookRewriteOperationSnapshot(
      lorebookId: lorebookId,
      entryId: entryId,
      baseContent: baseContent,
      expectedContentHash: expectedContentHash,
      patches: List.unmodifiable(patches),
    );
  }
}

/// The single serialization shape for operation snapshots.
///
/// [encode] emits exactly the durable request shape accepted by manual apply
/// (`ManualRewriteApplyRepo`): `{field, patches, transition}` with patches as
/// `{scopeKey, anchor, anchorSha256, value}` and transition as `{id, scopeKey,
/// canonicalClaim, promotionDestination, affectedTrackerKeys, factIds,
/// chatSessionId}`. Key order is fixed, so encoding is byte-deterministic.
///
/// [tryDecode] mirrors the apply-side structural bar (recognized field,
/// non-empty patches of strings, required transition members) and applies the
/// apply-side defaults (`promotionDestination` → `''`, `factIds` → `[]`).
/// It performs NO semantic validation — scope grammar, anchor hashes, and
/// budgets belong to the parser and [AnchoredScalarPatchValidator].
abstract final class ManualRewriteOperationSnapshotCodec {
  static String encode(CardRewriteOperationSnapshot snapshot) =>
      jsonEncode(_operationJson(snapshot));

  static CardRewriteOperationSnapshot? tryDecode(Object? json) {
    if (json is! Map) return null;
    final fieldValue = json['field'];
    if (fieldValue is! String) return null;
    final field = _fieldFromWireName(fieldValue);
    if (field == null) return null;
    final patchesValue = json['patches'];
    if (patchesValue is! List || patchesValue.isEmpty) return null;
    final patches = <AnchoredScalarPatch>[];
    for (final rawPatch in patchesValue) {
      if (rawPatch is! Map) return null;
      final scopeKey = rawPatch['scopeKey'];
      final anchor = rawPatch['anchor'];
      final anchorSha256 = rawPatch['anchorSha256'];
      final value = rawPatch['value'];
      if (scopeKey is! String ||
          anchor is! String ||
          anchorSha256 is! String ||
          value is! String) {
        return null;
      }
      patches.add(
        AnchoredScalarPatch(
          scopeKey: scopeKey,
          field: field,
          anchor: anchor,
          anchorSha256: anchorSha256,
          value: value,
        ),
      );
    }
    final transition = _tryDecodeTransition(json['transition']);
    if (transition == null) return null;
    return CardRewriteOperationSnapshot(
      field: field,
      patches: List<AnchoredScalarPatch>.unmodifiable(patches),
      transition: transition,
    );
  }

  static Map<String, Object?> _operationJson(
    CardRewriteOperationSnapshot snapshot,
  ) => {
    'field': snapshot.field.wireName,
    'patches': [for (final patch in snapshot.patches) _patchJson(patch)],
    'transition': _transitionJson(snapshot.transition),
  };

  static Map<String, Object?> _patchJson(AnchoredScalarPatch patch) => {
    'scopeKey': patch.scopeKey,
    'anchor': patch.anchor,
    'anchorSha256': patch.anchorSha256,
    'value': patch.value,
  };

  static Map<String, Object?> _transitionJson(
    CardRewriteTransitionSnapshot transition,
  ) => {
    'id': transition.id,
    'scopeKey': transition.scopeKey,
    'canonicalClaim': transition.canonicalClaim,
    'promotionDestination': transition.promotionDestination,
    'affectedTrackerKeys': transition.affectedTrackerKeys,
    'factIds': transition.factIds,
    'chatSessionId': transition.chatSessionId,
  };

  static CardRewriteTransitionSnapshot? _tryDecodeTransition(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final scopeKey = json['scopeKey'];
    final canonicalClaim = json['canonicalClaim'];
    final promotionDestination = json['promotionDestination'];
    final chatSessionId = json['chatSessionId'];
    if (id is! String || scopeKey is! String || canonicalClaim is! String) {
      return null;
    }
    if (promotionDestination is! String? || chatSessionId is! String?) {
      return null;
    }
    final affectedTrackerKeys = _tryDecodeStringList(
      json['affectedTrackerKeys'],
    );
    if (affectedTrackerKeys == null) return null;
    final factIdsValue = json['factIds'];
    final factIds = factIdsValue == null
        ? const <String>[]
        : _tryDecodeStringList(factIdsValue);
    if (factIds == null) return null;
    return CardRewriteTransitionSnapshot(
      id: id,
      scopeKey: scopeKey,
      canonicalClaim: canonicalClaim,
      promotionDestination: promotionDestination ?? '',
      affectedTrackerKeys: affectedTrackerKeys,
      factIds: factIds,
      chatSessionId: chatSessionId,
    );
  }

  static List<String>? _tryDecodeStringList(Object? value) {
    if (value is! List) return null;
    final result = <String>[];
    for (final element in value) {
      if (element is! String) return null;
      result.add(element);
    }
    return List<String>.unmodifiable(result);
  }

  static CardRewriteField? _fieldFromWireName(String wireName) {
    for (final field in CardRewriteField.values) {
      if (field.wireName == wireName) return field;
    }
    return null;
  }
}
