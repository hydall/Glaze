import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/presets/preset_list_provider.dart';
import 'package:glaze_flutter/features/regex/regex_sheet.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';

/// Serves one preset with one script and swallows the debounced save, so the
/// sheet never reaches the database.
class _StubPresetList extends PresetListNotifier {
  _StubPresetList(this.presets);

  final List<Preset> presets;

  @override
  Future<List<Preset>> build() async => presets;

  @override
  Future<void> updatePreset(Preset preset) async {}
}

/// Settings that never touch SharedPreferences.
class _StubSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a back gesture in the regex editor returns to the list, then '
      'closes the sheet', (tester) async {
    final preset = Preset(
      id: 'p1',
      name: 'Preset',
      regexes: [const PresetRegex(id: 'r1', name: 'Script', regex: 'foo')],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(_StubSettings.new),
          presetListProvider.overrideWith(() => _StubPresetList([preset])),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => const RegexSheet(presetId: 'p1'),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // The list is showing: the add FAB belongs to it.
    expect(find.byType(FloatingActionButton), findsOneWidget);

    // Open the script's editor — the FAB goes away with the list.
    await tester.tap(find.text('Script'));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsNothing);

    // First back unwinds to the list instead of dismissing the sheet.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsOneWidget);

    // Nothing left inside — now back closes the sheet itself.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('Script'), findsNothing);
  });
}
