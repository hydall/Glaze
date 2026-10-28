import 'character_card_fields.dart';

enum CharacterProposalKind { create, update }

/// One field of a proposed card, with its current value when the card
/// already exists.
class CharacterFieldChange {
  const CharacterFieldChange({
    required this.field,
    required this.after,
    this.before,
  });

  final CharacterCardField field;
  final Object? before;
  final Object after;
}

/// A library write the model asked for, as the confirmation sheet shows it.
class CharacterToolProposal {
  const CharacterToolProposal({
    required this.kind,
    required this.characterName,
    required this.changes,
    this.lorebookName,
    this.lorebookEntryCount = 0,
  });

  final CharacterProposalKind kind;

  /// The card's name after the write.
  final String characterName;
  final List<CharacterFieldChange> changes;

  /// The embedded lorebook a new card brings along, if any.
  final String? lorebookName;
  final int lorebookEntryCount;
}
