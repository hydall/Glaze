import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The API sheet's tab strip: LLM, then Agents — both are connections a chat
/// runs on. Embeddings have a screen of their own (Tools → Embeddings, the
/// chat drawer), so the API sheet no longer carries them.
void main() {
  final screen = File(
    'lib/features/settings/api_settings_screen.dart',
  ).readAsStringSync();

  test('the strip reads LLM, Agents', () {
    final llm = screen.indexOf("label: 'tab_llm'.tr()");
    final agents = screen.indexOf("label: 'studio_agents'.tr()");
    expect(llm, greaterThan(-1));
    expect(agents, greaterThan(llm));
  });

  test('the API sheet has no Embeddings tab', () {
    expect(screen, isNot(contains("label: 'tab_embeddings'.tr()")));
    expect(screen, isNot(contains('_buildEmbeddingsTab(')));
    expect(screen, isNot(contains('embeddingPresetListProvider')));
  });

  test('the bodies follow the strip', () {
    expect(screen, contains('// 0 = LLM, 1 = auxiliary connections'));
    expect(screen, contains('0 => _buildLlmTab(list, activeName),'));
    expect(screen, contains('_ => AuxSlotsTab('));
  });

  test('a deep link at the MemoryBook slot opens the Agents tab', () {
    expect(screen, contains('ApiSettingsSection.memoryBook => 1,'));
  });

  test('each tab scrolls its own list', () {
    expect(screen, contains('0 => _llmScrollController,'));
    expect(screen, contains('_ => _agentsScrollController,'));
  });
}
