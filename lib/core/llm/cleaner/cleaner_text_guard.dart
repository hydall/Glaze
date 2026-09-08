/// Text-rewrite safety guards for the POST-cleaner.
///
/// Presence-only checks that detect when a cleaner rewrite catastrophically
/// dropped protected markup (inline HTML/XML tags, fenced code blocks, or
/// meta-OOC blocks) that was present in the original assistant response. When
/// any guard returns `true`, the caller keeps the original text instead of
/// applying the cleaned version.
///
/// Ported from Marinara `text-rewrite-safety.ts`. Does NOT verify the *same*
/// tags/fences survive — only that *some* survive. Structural preservation is
/// the cleaner prompt's responsibility; these guards only catch the
/// catastrophic case of the cleaner stripping ALL formatting.
class CleanerTextGuard {
  /// Returns true if [original] had inline HTML/XML tags or fenced code blocks
  /// and [edited] no longer has any.
  ///
  /// - Inline HTML/XML tags: matches `</?[a-zA-Z][^>]*>` (a `<` followed by an
  ///   optional `/` and a letter — excludes `==...==` markdown markers and
  ///   inline `code` single backticks).
  /// - Fenced code blocks: matches the triple-backtick fence ```` ``` ````.
  static bool textRewriteDropsProtectedMarkup(String original, String edited) {
    final originalHasTags = _hasHtmlOrXmlTag(original);
    final originalHasFences = _hasFencedBlock(original);
    if (!originalHasTags && !originalHasFences) return false;
    if (originalHasTags && !_hasHtmlOrXmlTag(edited)) return true;
    if (originalHasFences && !_hasFencedBlock(edited)) return true;
    return false;
  }

  static bool _hasHtmlOrXmlTag(String text) {
    return RegExp(r'</?[a-zA-Z][^>]*>').hasMatch(text);
  }

  static bool _hasFencedBlock(String text) {
    return text.contains('```');
  }

  /// True if [original] contained a meta-OOC block (e.g. `<lumiaooc>`,
  /// `<oocnote>`, `<metaooc>`, or any tag whose name contains "ooc") and
  /// [edited] no longer has any.
  ///
  /// The meta-OOC block is meta-commentary addressed to the user outside the
  /// roleplay — it is NOT prose to be cleaned. The cleaner is instructed to
  /// preserve it verbatim; this guard catches the case where the cleaner
  /// stripped it anyway. The detection is generalized: any `<...ooc...>` tag
  /// (case-insensitive) counts, so custom meta-personas with custom wrappers
  /// are preserved too. Rationale: `<lumiaooc>` is meta-OOC commentary, not
  /// prose — the cleaner is instructed to preserve it verbatim, and this guard
  /// catches the case where it stripped it anyway (reject the rewrite).
  static bool lumiaoocDropped(String original, String edited) {
    final pattern = RegExp(r'<\w*ooc\w*>', caseSensitive: false);
    if (!pattern.hasMatch(original)) return false;
    if (pattern.hasMatch(edited)) return false;
    return true;
  }
}
