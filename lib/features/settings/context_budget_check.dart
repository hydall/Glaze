import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/llm/tokenizer.dart';
import '../../core/models/api_config.dart';
import '../../core/models/preset.dart';
import '../../core/models/preset_block_groups.dart';
import '../../shared/widgets/help_tip.dart';

/// Tokens [preset] puts into every prompt: its enabled blocks, folder switches
/// applied, stashed blocks left out — the same count the preset editor's
/// dashboard shows. Macros are counted as written.
int presetPromptTokens(Preset preset) =>
    applyPresetFolderEnablement(preset.blocks, preset.blockFolders)
        .where((b) => b.enabled && !b.isStashed && b.content.isNotEmpty)
        .fold(0, (sum, b) => sum + estimateTokens(b.content));

/// Whether a preset of [presetTokens] fits what the context window leaves for
/// the prompt once the reply is reserved. When it does not, the history trim
/// has nothing to spend and every message is cut from the request.
bool presetFitsContext({
  required int presetTokens,
  required int contextSize,
  required int maxTokens,
}) {
  if (presetTokens <= 0) return true;
  return presetTokens <=
      contextSize - clampMaxOutputTokens(maxTokens, contextSize);
}

/// The "preset won't fit" hint, ending in a link to the Context Size glossary
/// term. Shared by the API settings form and the chat's send guard so both say
/// the same thing.
class PresetFitWarningText extends ConsumerWidget {
  final TextStyle style;
  final TextAlign textAlign;

  const PresetFitWarningText({
    super.key,
    required this.style,
    this.textAlign = TextAlign.start,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Text.rich(
      textAlign: textAlign,
      TextSpan(
        style: style,
        children: [
          TextSpan(text: 'warning_preset_exceeds_context'.tr()),
          TextSpan(text: ' ${'warning_preset_exceeds_context_see'.tr()} '),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => openGlossaryTerm(context, ref, 'context-size'),
                child: Text(
                  '"${'label_context_size'.tr()}"',
                  style: style.copyWith(
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                    decorationColor: style.color,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
