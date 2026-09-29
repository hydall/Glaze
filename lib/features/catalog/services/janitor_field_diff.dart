/// Recovers lorebook text that was injected into fields the character owns —
/// the scenario, the persona/personality, the example dialogue, the first
/// message — instead of being appended as a block of its own.
///
/// [separate] can only isolate what sits *outside* `<...Persona>` /
/// `<Scenario>` / `<Example...>`: it drops those blocks whole, so anything a
/// lorebook wrote inside them goes with them. Advanced (Nine API) scripts write
/// there routinely, and so does a plain `lorebook` book: every entry has a
/// `placement` (`default` / `personality` / `scenario` / `example_dialogs`)
/// and a `placementPosition` (`before` / `after`), and anything but `default`
/// writes the entry into that field instead of a block of its own. The first
/// message never reaches the separator at all —
/// it is an assistant turn, not part of the system message.
///
/// The recovery is a diff, not a guess. Every capture sends two messages: a bare
/// `"."` and then the real trigger text (see `captureGenerateAlpha`). The first
/// assembles a prompt with almost nothing fired — a BEFORE snapshot — and the
/// second an AFTER. Whatever is in AFTER but not in BEFORE was injected by the
/// entries the trigger fired, wherever it landed.
///
/// A second pass compares the BEFORE snapshot against the character's public
/// catalog fields, to catch always-on entries: those fire in both snapshots and
/// so cancel out of the first pass. It needs a public definition, and is
/// skipped for a closed card — there is no clean baseline to compare against
/// and every guess would be indistinguishable from the card itself.
///
/// An always-on entry the second pass cannot reach is left where it is, inside
/// the imported card. That is a deliberate choice, not a gap to work around:
/// text that is in the prompt on every single turn is part of the character in
/// everything but name, and reads that way in the card. Only the entries that
/// come and go with the keys are worth recovering as a lorebook.
///
/// No Flutter / IO dependencies — deterministic and unit-tested, like
/// [janitor_separate.dart] next to it.
library;

import 'janitor_separate.dart';

/// A prompt field a lorebook can be injected into.
enum InjectionField { persona, scenario, example, firstMessage }

/// The four injectable fields of one assembled prompt (or of the clean catalog
/// metadata the prompt was assembled from).
class PromptFields {
  final String persona;
  final String scenario;
  final String example;
  final String firstMessage;

  const PromptFields({
    this.persona = '',
    this.scenario = '',
    this.example = '',
    this.firstMessage = '',
  });

  static const empty = PromptFields();

  /// Reads the fields out of a captured `generateAlpha` payload.
  ///
  /// [restore] is applied to every field as it is read — pass the extractor's
  /// macro restoration so the captured text (where JanitorAI has already
  /// expanded `{{char}}` into the real name) lines up with catalog metadata,
  /// which still carries the macros.
  factory PromptFields.fromPayload(
    Map<String, dynamic> payload, {
    String Function(String)? restore,
  }) {
    String read(String s) => restore == null ? s : restore(s);
    return PromptFields(
      persona: read(extractCard(payload)),
      scenario: read(extractScenario(payload)),
      example: read(extractExample(payload)),
      firstMessage: read(extractFirstMessage(payload)),
    );
  }

  /// The clean, pre-injection fields as the catalog publishes them
  /// (`/hampter/characters/{id}`). Only meaningful for a character whose
  /// definition is public — a closed card returns empty fields, which the scan
  /// then skips rather than reading as "everything was injected".
  ///
  /// Every greeting is folded into [firstMessage]: the comparison is by line, so
  /// which greeting the captured chat happened to open with does not matter.
  factory PromptFields.fromMeta(Map<String, dynamic>? meta) {
    if (meta == null) return empty;
    String str(Object? v) => (v ?? '').toString();
    final greetings = <String>[
      str(meta['first_message']),
      if (meta['first_messages'] is List)
        ...(meta['first_messages'] as List).whereType<String>(),
    ].where((g) => g.trim().isNotEmpty).join('\n');
    return PromptFields(
      persona: str(meta['personality']),
      scenario: str(meta['scenario']),
      example: str(meta['example_dialogs'] ?? meta['mes_example']),
      firstMessage: greetings,
    );
  }

  String operator [](InjectionField field) => switch (field) {
        InjectionField.persona => persona,
        InjectionField.scenario => scenario,
        InjectionField.example => example,
        InjectionField.firstMessage => firstMessage,
      };

  bool get isEmpty => InjectionField.values.every((f) => this[f].trim().isEmpty);
}

/// One block of lorebook text recovered from [field].
class InjectedBlock {
  final InjectionField field;
  final String text;
  const InjectedBlock(this.field, this.text);
}

/// What [scanInjectedFields] recovered.
class InjectionScan {
  final List<InjectedBlock> blocks;
  const InjectionScan(this.blocks);

  static const none = InjectionScan([]);

  bool get isEmpty => blocks.isEmpty;
  bool get isNotEmpty => blocks.isNotEmpty;
  int get length => blocks.length;

  /// The recovered text, blank-line separated and **unlabelled**. The build
  /// prompt reads this as entry bodies, and would cheerfully emit a "(from
  /// scenario)" label as if it were content — provenance stays on the blocks,
  /// for the UI to show.
  String get text => blocks.map((b) => b.text).join('\n\n');

  Set<InjectionField> get fields => blocks.map((b) => b.field).toSet();
}

/// Shortest block worth reporting, measured after folding. Injected lore is a
/// sentence or more; anything shorter is punctuation, a stray heading or a line
/// that drifted past the comparison, and reporting it as an entry is worse than
/// dropping it.
const int _minInjectionChars = 24;

/// Case-, whitespace- and glyph-insensitive form of [s], used to decide whether
/// two lines are "the same line". Folds the same quote/apostrophe/dash variants
/// [loosePattern] tolerates — the server rewrites those freely between one
/// assembled prompt and the next.
String _fold(String s) => s
    .replaceAll(RegExp(r'''['‘’ʼ]'''), "'")
    .replaceAll(RegExp(r'["“”]'), '"')
    .replaceAll(RegExp(r'[-–—]'), '-')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .toLowerCase();

/// The lines of [after] that do not appear anywhere in [before], regrouped into
/// contiguous blocks.
///
/// Deliberately a line-set subtraction rather than a positional diff: an
/// injection lands *inside* the field, splitting the baseline around it, so
/// matching the baseline as one run would fail exactly when it matters. Blocks
/// break wherever a baseline line was dropped, which is where the injection
/// ends.
List<String> _residue(String after, String before) {
  if (after.trim().isEmpty) return const [];
  final known = <String>{};
  for (final line in before.split('\n')) {
    final folded = _fold(line);
    if (folded.isNotEmpty) known.add(folded);
  }
  final blocks = <String>[];
  final current = <String>[];
  void flush() {
    final text = current.join('\n').trim();
    current.clear();
    if (_fold(text).length >= _minInjectionChars) blocks.add(text);
  }

  for (final line in after.split('\n')) {
    final folded = _fold(line);
    if (folded.isNotEmpty && known.contains(folded)) {
      flush();
    } else {
      current.add(line);
    }
  }
  flush();
  return blocks;
}

/// Recovers the lorebook text injected into [capture]'s own fields.
///
/// [probe] is the BEFORE snapshot (the `"."` send); with it, pass one reports
/// everything the trigger fired. [clean] is the character's public catalog
/// definition; with it, pass two reports the always-on entries that fire in
/// both snapshots. Either may be absent — with neither, nothing is reported,
/// because every candidate would be indistinguishable from the card.
///
/// [publicContents] are the verbatim entries of the character's public
/// lorebooks, subtracted from what is recovered so a public book injected into
/// the scenario is not handed back as closed-lorebook material. [existing] is
/// whatever the separator already isolated — text already in there is not
/// reported a second time.
InjectionScan scanInjectedFields({
  required PromptFields capture,
  PromptFields? probe,
  PromptFields? clean,
  List<String> publicContents = const [],
  String existing = '',
}) {
  if (probe == null && clean == null) return InjectionScan.none;
  final blocks = <InjectedBlock>[];
  // Both passes can surface the same text (an entry that fired on the probe and
  // on the trigger); report it once.
  final seen = <String>{};
  final alreadyIsolated = _fold(existing);

  void collect(InjectionField field, String after, String before) {
    for (final block in _residue(after, before)) {
      final text = withoutPublicEntries(block, publicContents).trim();
      final folded = _fold(text);
      if (folded.length < _minInjectionChars) continue;
      if (alreadyIsolated.contains(folded)) continue;
      if (!seen.add(folded)) continue;
      blocks.add(InjectedBlock(field, text));
    }
  }

  for (final field in InjectionField.values) {
    final after = capture[field];
    if (after.trim().isEmpty) continue;
    // Pass one — what the trigger fired, whatever field it landed in.
    if (probe != null) collect(field, after, probe[field]);
    // Pass two — what is always on. An empty clean field is not a baseline: it
    // means the catalog withholds that field, and treating "" as "nothing was
    // there before" would report the entire field as injected lore.
    final baseline = clean?[field] ?? '';
    if (baseline.trim().isNotEmpty) {
      collect(field, probe?[field] ?? after, baseline);
    }
  }
  return InjectionScan(blocks);
}

/// [text] with every line [scan] recovered from [field] taken back out.
///
/// What the scan reports goes into the lorebook, so it has no business staying
/// in the imported card as well — the entry would reach the prompt twice, once
/// always-on. Matched by line with the same folding the scan compares by: the
/// blocks are made of whole field lines, but may have had public-lorebook text
/// cut out of them since, so a match on the whole block would miss.
String withoutInjected(String text, InjectionField field, InjectionScan scan) {
  final injected = <String>{
    for (final block in scan.blocks)
      if (block.field == field)
        for (final line in block.text.split('\n'))
          if (_fold(line).isNotEmpty) _fold(line),
  };
  if (injected.isEmpty || text.isEmpty) return text;
  return text
      .split('\n')
      .where((line) => !injected.contains(_fold(line)))
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
