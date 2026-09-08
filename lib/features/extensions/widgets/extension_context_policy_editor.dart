import 'package:flutter/material.dart';

import '../models/extension_context_policy.dart';

class ExtensionContextPolicyEditor extends StatelessWidget {
  const ExtensionContextPolicyEditor({
    required this.policy,
    required this.onChanged,
    super.key,
  });

  final ExtensionContextPolicy policy;
  final ValueChanged<ExtensionContextPolicy> onChanged;

  void _update(
    ExtensionContextPolicy Function(ExtensionContextPolicy current) update,
  ) {
    onChanged(update(policy).copyWith(legacyPromptSemantics: false));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text(
            'Передавать тот же контекст, что и в основную модель',
          ),
          subtitle: const Text(
            'Этот блок может использовать другого API-провайдера. Полный '
            'контекст увеличивает стоимость и передаёт ему карточку, память '
            'и инструкции основного запроса.',
          ),
          value: policy.useMainModelContext,
          onChanged: (value) => _update(
            (current) => current.copyWith(useMainModelContext: value),
          ),
          contentPadding: EdgeInsets.zero,
        ),
        if (!policy.useMainModelContext)
          ExpansionTile(
            title: const Text('Настроить контекст блока'),
            childrenPadding: const EdgeInsets.only(bottom: 12),
            tilePadding: EdgeInsets.zero,
            children: [
              _toggle('Карточка персонажа', policy.includeCharacterCard, (v) {
                _update((current) => current.copyWith(includeCharacterCard: v));
              }),
              _toggle('Персона пользователя', policy.includePersona, (v) {
                _update((current) => current.copyWith(includePersona: v));
              }),
              _toggle(
                'Инструкции основного пресета',
                policy.includeMainPresetInstructions,
                (v) => _update(
                  (current) =>
                      current.copyWith(includeMainPresetInstructions: v),
                ),
              ),
              _toggle('Lorebooks', policy.includeLorebooks, (v) {
                _update((current) => current.copyWith(includeLorebooks: v));
              }),
              _toggle('MemoryBooks и raw recall', policy.includeMemoryBooks, (
                v,
              ) {
                _update((current) => current.copyWith(includeMemoryBooks: v));
              }),
              _toggle('Studio Ledger / state', policy.includeStudioState, (v) {
                _update((current) => current.copyWith(includeStudioState: v));
              }),
              _toggle('Summary', policy.includeSummary, (v) {
                _update((current) => current.copyWith(includeSummary: v));
              }),
              _toggle('Author’s note', policy.includeAuthorsNote, (v) {
                _update((current) => current.copyWith(includeAuthorsNote: v));
              }),
              _toggle(
                'Runtime prompt injections',
                policy.includeRuntimePrompts,
                (v) => _update(
                  (current) => current.copyWith(includeRuntimePrompts: v),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _toggle(String title, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      value: value,
      onChanged: onChanged,
    );
  }
}
