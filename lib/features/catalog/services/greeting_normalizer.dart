/// The greetings of a downloaded card, in the shape SillyTavern V2 wants.
typedef NormalizedGreetings = ({String firstMes, List<String> alternates});

/// Folds every greeting a provider handed over into one `firstMes` plus its
/// alternates.
///
/// Providers disagree about where a card's greetings live, and the disagreement
/// is not cosmetic:
///
/// * JanitorAI carries the opening line in `first_message` **and** in
///   `first_messages`, which holds the whole set including that one. Mapping
///   the plural field straight onto the alternates therefore duplicated the
///   opening greeting.
/// * DataCat mirrors Janitor rows, and on some cards the singular field is
///   empty while the set is not. Reading only `first_message` left slot one
///   blank and every greeting shifted down by one — the reader saw the card
///   "skip the first greeting", while downloading the same card from DataCat's
///   own site did not.
///
/// So the rule is stated once, here, rather than four times with three
/// different answers: take the greetings in preference order, drop the blanks,
/// drop the repeats, and the first one that survives is the card's opening
/// line. A card whose singular field is empty is not a card without a
/// greeting — it is a card whose greeting is first in the list.
///
/// Order is preserved rather than sorted: for a card with several greetings the
/// order is the author's, and the reader pages through them in it.
NormalizedGreetings normalizeGreetings({
  String? primary,
  List<String?> others = const [],
}) {
  final ordered = <String>[];
  final seen = <String>{};
  for (final candidate in <String?>[primary, ...others]) {
    final greeting = (candidate ?? '').trim();
    if (greeting.isEmpty) continue;
    if (!seen.add(greeting)) continue;
    ordered.add(greeting);
  }
  return (
    firstMes: ordered.isEmpty ? '' : ordered.first,
    alternates: ordered.length > 1
        ? List<String>.unmodifiable(ordered.sublist(1))
        : const <String>[],
  );
}

/// The strings in [value] when it is a list of them, else nothing.
///
/// Providers answer these fields with a list, a null, an empty list, or (for a
/// field a row simply does not have) something else entirely; every caller was
/// writing the same `is List` dance around it.
List<String> greetingList(Object? value) => value is List
    ? value.whereType<String>().toList()
    : const <String>[];
