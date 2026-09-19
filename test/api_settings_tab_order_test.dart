import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The API sheet's tab strip: LLM, Agents, Embeddings. Agents sits next to LLM
/// because both are connections a chat runs on; embeddings are the odd one out
/// and belong at the end.
void main() {
  final screen = File(
    'lib/features/settings/api_settings_screen.dart',
  ).readAsStringSync();

  test('the strip reads LLM, Agents, Embeddings', () {
    final llm = screen.indexOf("label: 'LLM'");
    final agents = screen.indexOf("label: 'studio_agents'.tr()");
    final embeddings = screen.indexOf("label: 'tab_embeddings'.tr()");
    expect(llm, greaterThan(-1));
    expect(agents, greaterThan(llm));
    expect(embeddings, greaterThan(agents));
  });

  test('the bodies follow the strip', () {
    expect(screen, contains('// 0 = LLM, 1 = Studio agents, 2 = Embeddings'));
    final agentsTab = screen.indexOf('1 => StudioSlotsTab(');
    expect(agentsTab, greaterThan(-1));
    // The embeddings tab is the default arm, after the agents one.
    expect(screen.indexOf('_buildEmbeddingsTab(', agentsTab), greaterThan(-1));
  });

  test('a deep link at the MemoryBook slot opens the Agents tab', () {
    expect(
      screen,
      contains(
        '_tab = widget.focusSection == ApiSettingsSection.memoryBook ? 1 : 0;',
      ),
    );
  });

  test('each tab scrolls its own list', () {
    expect(screen, contains('1 => _agentsScrollController,'));
    expect(screen, contains('_ => _embScrollController,'));
  });
}
