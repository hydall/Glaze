import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/menu_group.dart';
import '../models/extension_context_policy.dart';

/// The context rows of the block editor: whether a block reuses the main
/// request's context, and — when it does not — what it assembles instead.
///
/// It hands back rows rather than a widget of its own so the caller can place
/// the master switch among its other context settings and give the detail
/// toggles a card of their own, instead of nesting one card inside another.
class ExtensionContextPolicyEditor {
  const ExtensionContextPolicyEditor({
    required this.policy,
    required this.onChanged,
  });

  final ExtensionContextPolicy policy;
  final ValueChanged<ExtensionContextPolicy> onChanged;

  void _update(
    ExtensionContextPolicy Function(ExtensionContextPolicy current) update,
  ) {
    onChanged(update(policy).copyWith(legacyPromptSemantics: false));
  }

  /// "Reuse the main model's context", for the block's context group.
  Widget mainSwitch() => MenuSwitchItem(
    label: 'block_ctx_use_main'.tr(),
    description: 'block_ctx_use_main_desc'.tr(),
    value: policy.useMainModelContext,
    onChanged: (value) =>
        _update((current) => current.copyWith(useMainModelContext: value)),
  );

  /// What the block's own context is built from. Null while the block reuses
  /// the main request's, where none of it applies.
  Widget? detailsGroup() {
    if (policy.useMainModelContext) return null;
    return MenuGroup(
      header: 'block_ctx_custom'.tr(),
      items: [
        _toggle('block_ctx_character_card', policy.includeCharacterCard, (v) {
          _update((current) => current.copyWith(includeCharacterCard: v));
        }),
        _toggle('block_ctx_persona', policy.includePersona, (v) {
          _update((current) => current.copyWith(includePersona: v));
        }),
        _toggle(
          'block_ctx_main_instructions',
          policy.includeMainPresetInstructions,
          (v) => _update(
            (current) => current.copyWith(includeMainPresetInstructions: v),
          ),
        ),
        _toggle('block_ctx_lorebooks', policy.includeLorebooks, (v) {
          _update((current) => current.copyWith(includeLorebooks: v));
        }),
        _toggle('block_ctx_memory', policy.includeMemoryBooks, (v) {
          _update((current) => current.copyWith(includeMemoryBooks: v));
        }),
        _toggle('block_ctx_studio_state', policy.includeStudioState, (v) {
          _update((current) => current.copyWith(includeStudioState: v));
        }),
        _toggle('block_ctx_summary', policy.includeSummary, (v) {
          _update((current) => current.copyWith(includeSummary: v));
        }),
        _toggle('block_ctx_authors_note', policy.includeAuthorsNote, (v) {
          _update((current) => current.copyWith(includeAuthorsNote: v));
        }),
        _toggle('block_ctx_runtime_prompts', policy.includeRuntimePrompts, (v) {
          _update((current) => current.copyWith(includeRuntimePrompts: v));
        }),
      ],
    );
  }

  Widget _toggle(String labelKey, bool value, ValueChanged<bool> onChanged) =>
      MenuSwitchItem(label: labelKey.tr(), value: value, onChanged: onChanged);
}
