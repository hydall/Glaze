/// Matching of reference-library entries against an image prompt.
///
/// Ported from https://github.com/0xl0cal/sillyimages (`src/parser.js`):
/// comma-separated aliases, word-boundary matching (so "ann" does not fire on
/// "announcement"), plus the `always` mode that bypasses matching entirely.
library;

import '../image_gen_models.dart';

String normalizeTriggerText(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

/// Comma-separated alias list of one reference entry.
List<String> parseReferenceAliases(String name) => name
    .split(',')
    .map(normalizeTriggerText)
    .where((alias) => alias.isNotEmpty)
    .toList();

/// True when [alias] occurs in [prompt] as a whole word. Internal whitespace in
/// the alias matches any run of whitespace.
bool promptContainsReferenceName(String prompt, String alias) {
  final normalizedPrompt = normalizeTriggerText(prompt);
  final normalizedAlias = normalizeTriggerText(alias);
  if (normalizedPrompt.isEmpty || normalizedAlias.isEmpty) return false;

  final pattern = RegExp.escape(normalizedAlias).replaceAll(r'\ ', r'\s+');
  try {
    final regex = RegExp(
      '(^|[^\\p{L}\\p{N}_])$pattern(?=\$|[^\\p{L}\\p{N}_])',
      caseSensitive: false,
      unicode: true,
    );
    return regex.hasMatch(normalizedPrompt);
  } catch (_) {
    return normalizedPrompt.contains(normalizedAlias);
  }
}

/// References that should be attached to a request for [prompt]: `always`
/// entries plus every entry whose alias appears in the prompt. Disabled and
/// image-less entries are skipped; duplicates (same name + image) collapse.
List<ReferenceImage> matchReferences(
  String prompt,
  List<ReferenceImage> library,
) {
  final matched = <ReferenceImage>[];
  final seen = <String>{};

  for (final ref in library) {
    if (!ref.enabled || ref.imageData.isEmpty) continue;
    final name = ref.name.trim();
    final isMatch =
        ref.matchMode == 'always' ||
        (name.isNotEmpty &&
            parseReferenceAliases(
              name,
            ).any((alias) => promptContainsReferenceName(prompt, alias)));
    if (!isMatch) continue;
    if (!seen.add('$name::${ref.imageData}')) continue;
    matched.add(ref);
  }

  return matched;
}
