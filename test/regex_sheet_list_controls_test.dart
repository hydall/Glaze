import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/presets/preset_list_provider.dart';
import 'package:glaze_flutter/features/regex/regex_sheet.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_fab.dart';
import 'package:glaze_flutter/shared/widgets/list_controls.dart';
import 'package:glaze_flutter/shared/widgets/selection_bar.dart';

/// Serves one preset and records what the sheet writes back to it.
class _StubPresetList extends PresetListNotifier {
  _StubPresetList(this.presets);

  final List<Preset> presets;
  final List<Preset> saved = [];

  @override
  Future<List<Preset>> build() async => presets;

  @override
  Future<void> updatePreset(Preset preset) async {
    saved.add(preset);
    state = AsyncData([preset]);
  }
}

class _StubSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

void main() {
  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
  });

  Future<_StubPresetList> open(WidgetTester tester) async {
    final presets = _StubPresetList([
      Preset(
        id: 'p1',
        name: 'Preset',
        regexes: const [
          PresetRegex(id: 'r1', name: 'First', regex: 'a'),
          PresetRegex(id: 'r2', name: 'Second', regex: 'b'),
          PresetRegex(id: 'r3', name: 'Third', regex: 'c'),
        ],
      ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDbProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith(_StubSettings.new),
          presetListProvider.overrideWith(() => presets),
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
    return presets;
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('the header carries the scope, filter and sort controls', (
    tester,
  ) async {
    await open(tester);
    expect(find.byType(GlazeDropdownChip), findsOneWidget);
    expect(find.byType(GlazeFilterIconButton), findsOneWidget);
    expect(find.byType(PresetSortControls), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('a long press selects, taps add to it, and the bulk action '
      'disables every picked script at once', (tester) async {
    final presets = await open(tester);

    await tester.longPress(find.text('First'));
    await tester.pumpAndSettle();
    // Selecting swaps the add button for the selection bar.
    expect(find.byType(GlazeSelectionBar), findsOneWidget);
    expect(find.byType(GlazeFab), findsNothing);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

    await tester.tap(find.text('Third'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('regex_disable_selected'));
    await tester.pumpAndSettle();

    final written = presets.saved.last.regexes;
    expect({for (final r in written) r.id: r.disabled}, {
      'r1': true,
      'r2': false,
      'r3': true,
    });
    // Done: the selection is gone and the list is back to normal.
    expect(find.byType(GlazeSelectionBar), findsNothing);
    expect(find.byType(GlazeFab), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('back drops the selection before it closes the sheet', (
    tester,
  ) async {
    await open(tester);
    await tester.longPress(find.text('Second'));
    await tester.pumpAndSettle();
    expect(find.byType(GlazeSelectionBar), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(GlazeSelectionBar), findsNothing);
    expect(find.text('Second'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsNothing);
    await teardown(tester);
  });
}
