import '../macro_engine.dart';
import '../../models/studio_config.dart';

/// Assembles an auxiliary-stage prompt (cleaner or ledger) from preset blocks
/// preset blocks instead of hardcoded text.
///
/// The aux stages (cleaner and ledger) historically built their LLM
/// prompts from hardcoded strings in Dart source. This assembler moves the
/// system/instruction text into the DB-backed [StudioPreset] so the user can
/// edit it in the preset editor, and keeps only the runtime data + output
/// structure templates in code (the parser depends on those).
///
/// Flow:
/// 1. Filter [blocks] to the target [section], enabled only, ordered by `order`.
/// 2. Resolve standard macros (`{{char}}`, `{{user}}`, `{{getvar::...}}`, etc.)
///    in each block's content via [MacroContext].
/// 3. Apply [customReplacements] for stage-specific placeholders that
///    `replaceMacros` does not handle (e.g. `{{recentHistoryText}}`).
/// 4. Concatenate all block contents separated by blank lines.
/// 5. Append [runtimeSuffix] — the code-owned output template / runtime data
///    that the parser depends on (JSON structure, `<glaze_memory_export>` etc.).
class StudioAuxPromptAssembler {
  const StudioAuxPromptAssembler();

  /// Build the full aux-stage prompt from preset blocks.
  ///
  /// [blocks] — all blocks from the StudioPreset (will be filtered by section).
  /// [section] — the preset section to use ('cleaner' or 'ledger').
  /// [macroCtx] — macro context for resolving `{{char}}`, `{{user}}`,
  ///   `{{getvar::...}}`, etc.
  /// [customReplacements] — stage-specific placeholder replacements applied
  ///   after macro resolution. Keys are the full `{{placeholder}}` string,
  ///   values are the replacement text. Entries with empty values cause the
  ///   placeholder to be removed (replaced with empty string).
  /// [runtimeSuffix] — code-owned text appended after all preset blocks
  ///   (output template, runtime data, parser-dependent structure).
  /// [skipBlockIds] — block ids to exclude even when enabled (e.g. when a
  ///   runtime condition makes a block irrelevant).
  String assemble({
    required List<StudioPresetBlock> blocks,
    required String section,
    required MacroContext macroCtx,
    Map<String, String> customReplacements = const {},
    String runtimeSuffix = '',
    Set<String> skipBlockIds = const {},
  }) {
    final sectionBlocks =
        blocks
            .where((b) => b.enabled && b.section == section)
            .where((b) => !skipBlockIds.contains(b.id))
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));

    final parts = <String>[];
    for (final block in sectionBlocks) {
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
