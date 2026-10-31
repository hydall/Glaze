import '../models/preset.dart';

/// Which passes a regex script runs in — the display, the outgoing prompt —
/// read off the two ways a script can say it.
///
/// SillyTavern's "Ephemerality" checkboxes are `markdownOnly` ("Alter Chat
/// Display") and `promptOnly` ("Alter Outgoing Prompt"), and an imported
/// script carries them. Glaze's editor writes the same two checkboxes into
/// its own `ephemerality` list instead — 1 for the display, 2 for the prompt.
/// The two drifted apart: an older importer stored every script with `[2]`
/// whatever its flags said, so a script flagged for the display never ran
/// there, and the editor's checkboxes showed a list the engine then vetoed
/// with the flags. One answer now: a script that carries either SillyTavern
/// flag follows the flags, and one that carries neither follows the list,
/// where an empty list means every pass (as it always did in the engine).
extension RegexPasses on PresetRegex {
  /// Whether the script says where it runs the SillyTavern way.
  bool get usesStFlags => markdownOnly || promptOnly;

  /// Runs over what the reader sees.
  bool get altersDisplay => usesStFlags
      ? markdownOnly
      : ephemerality.isEmpty || ephemerality.contains(1);

  /// Runs over what the model is sent.
  bool get altersPrompt => usesStFlags
      ? promptOnly
      : ephemerality.isEmpty || ephemerality.contains(2);

  /// The script with both ways of saying it set to [display] / [prompt] — what
  /// the editor writes, so the engine, the display list and an export to
  /// SillyTavern all read the same thing.
  PresetRegex withPasses({required bool display, required bool prompt}) =>
      copyWith(
        ephemerality: [if (display) 1, if (prompt) 2],
        markdownOnly: display,
        promptOnly: prompt,
      );
}
