import 'package:flutter/material.dart';

import '../../../core/services/memory_prompt_presets.dart';
import '../../../shared/widgets/prompt_preset_list.dart';

// The list itself lives in `lib/shared/widgets/prompt_preset_list.dart`, so the
// Memory Books and Summary settings — and their pickers — all render presets
// through one element. This wrapper only keeps the sheet's historical name.

export '../../../shared/widgets/prompt_preset_list.dart'
    show MemoryPromptPreviewSheet, showPromptPresetPicker;

/// Manage sheet for a prompt-preset library. Built-in presets are read-only
/// templates: they can only be previewed and duplicated into a custom copy.
class CustomPromptManagerSheet extends StatelessWidget {
  final List<MemoryPromptPreset> customPrompts;

  /// The read-only prompts shown above the custom ones, and the keys a new
  /// one may not collide with. Defaults to the Memory Books set; the summary
  /// settings pass their own.
  final List<MemoryPromptPreset> builtIn;

  /// Heading of the sheet. Defaults to the Memory Books one.
  final String? title;

  const CustomPromptManagerSheet({
    super.key,
    required this.customPrompts,
    this.builtIn = MemoryPromptPresets.builtIn,
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    return PromptPresetList(
      builtIn: builtIn,
      custom: customPrompts,
      title: title,
    );
  }
}
