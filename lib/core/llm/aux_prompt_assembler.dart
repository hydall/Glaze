import '../models/preset.dart';
import 'macro_engine.dart';

/// Assembles the prompt of an auxiliary engine (Post Clean or the Tracker)
/// from editable prompt blocks plus a code-owned suffix.
///
/// The instruction text lives in [PresetBlock]s so it can be edited; only the
/// runtime data and the output structure the parser depends on stay in code.
///
/// Flow:
/// 1. Keep the enabled [blocks] in list order, minus [skipBlockIds].
/// 2. Resolve standard macros (`{{char}}`, `{{user}}`, `{{getvar::...}}`, etc.)
///    in each block's content via [MacroContext].
/// 3. Apply [customReplacements] for stage-specific placeholders that
///    `replaceMacros` does not handle (e.g. `{{recentHistoryText}}`).
/// 4. Join the block contents with separators.
/// 5. Append [runtimeSuffix] — the code-owned output template / runtime data
///    that the parser depends on (JSON structure, `<glaze_memory_export>` etc.).
class AuxPromptAssembler {
  const AuxPromptAssembler();

  /// [customReplacements] keys are full `{{placeholder}}` strings; an empty
  /// value removes the placeholder. [skipBlockIds] excludes blocks even when
  /// enabled (e.g. when a runtime condition makes a block irrelevant).
  String assemble({
    required List<PresetBlock> blocks,
    required MacroContext macroCtx,
    Map<String, String> customReplacements = const {},
    String runtimeSuffix = '',
    Set<String> skipBlockIds = const {},
  }) {
    final parts = <String>[];
    for (final block in blocks) {
      if (!block.enabled || skipBlockIds.contains(block.id)) continue;
      var content = block.content;
      if (content.trim().isEmpty) continue;

      // Resolve standard macros ({{char}}, {{user}}, {{getvar::...}}, etc.).
      content = replaceMacros(content, macroCtx).text;

      // Apply stage-specific custom replacements ({{recentHistoryText}}, etc.).
      for (final entry in customReplacements.entries) {
        content = content.replaceAll(entry.key, entry.value);
      }

      if (content.trim().isEmpty) continue;
      parts.add(content.trim());
    }

    final systemText = parts.join('\n\n---\n\n');
    if (runtimeSuffix.isEmpty) return systemText;
    return '$systemText\n\n$runtimeSuffix';
  }
}
