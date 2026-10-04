import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/presets/preset_editor_screen.dart';
import 'package:glaze_flutter/features/presets/preset_list_provider.dart';
import 'package:glaze_flutter/features/presets/widgets/preset_block_row.dart';
import 'package:glaze_flutter/features/presets/widgets/preset_dashboard_card.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';

/// Settings that never touch SharedPreferences — the editor only reads
/// `addBlockAtTop` off them.
class _StubSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

/// Swallows the debounced save so the editor never reaches the database, and
/// records what it would have written.
class _StubPresetList extends PresetListNotifier {
  static final saved = <Preset>[];

  @override
  Future<List<Preset>> build() async => const [];

  @override
  Future<void> updatePreset(Preset preset) async => saved.add(preset);
}

void main() {
  PresetBlock block(String id, {bool stashed = false}) => PresetBlock(
    id: id,
    name: id,
    role: 'system',
    content: 'content of $id',
    isStashed: stashed,
  );

  Preset presetWith(List<PresetBlock> blocks) =>
      Preset(id: 'p1', name: 'Preset', blocks: blocks);

  // The dashboard card carries a stash button of its own (the drawer of put-away
  // blocks), so every finder here says where it is looking.
  Finder inHeader(IconData icon) =>
      find.descendant(of: find.byType(AppBar), matching: find.byIcon(icon));
  Finder inRows(IconData icon) => find.descendant(
    of: find.byType(PresetBlockRow),
    matching: find.byIcon(icon),
  );

  Future<void> pumpEditor(WidgetTester tester, Preset preset) async {
    PresetBlockEditorActions? actions;

    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(_StubSettings.new),
          presetListProvider.overrideWith(_StubPresetList.new),
        ],
        child: MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              appBar: AppBar(
                actions: actions == null
                    ? null
                    : presetBlockEditorHeaderActions(context, actions!),
              ),
              body: PresetEditorBody(
                preset: preset,
                onBlockEditorChanged: (a) => setState(() => actions = a),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openBlock(WidgetTester tester, {int at = 0}) async {
    await tester.tap(inRows(Icons.edit_outlined).at(at));
    await tester.pumpAndSettle();
  }

  /// Writes are debounced by half a second; let that timer run.
  Future<void> flushSave(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  setUp(_StubPresetList.saved.clear);

  testWidgets('the block list no longer carries a stash button', (
    tester,
  ) async {
    await pumpEditor(tester, presetWith([block('a'), block('b')]));

    expect(find.byType(PresetBlockRow), findsNWidgets(2));
    // Stash moved into the block's own editor. Left in the row it was a third
    // control competing with the drag handle, the pencil and the switch on a
    // 44px line.
    expect(inRows(Icons.archive_outlined), findsNothing);
    expect(inRows(Icons.unarchive_outlined), findsNothing);
  });

  testWidgets('opening a block hands the header its stash and delete buttons', (
    tester,
  ) async {
    await pumpEditor(tester, presetWith([block('a')]));

    expect(inHeader(Icons.archive_outlined), findsNothing);
    expect(inHeader(Icons.delete_outline), findsNothing);

    await openBlock(tester);

    expect(inHeader(Icons.archive_outlined), findsOneWidget);
    expect(inHeader(Icons.delete_outline), findsOneWidget);
    // …and nothing is left at the foot of the editor.
    expect(find.text('Delete Block'), findsNothing);
  });

  testWidgets('closing the editor takes the buttons away again', (
    tester,
  ) async {
    await pumpEditor(tester, presetWith([block('a')]));
    await openBlock(tester);
    expect(inHeader(Icons.delete_outline), findsOneWidget);

    final state = tester.state<PresetEditorBodyState>(
      find.byType(PresetEditorBody),
    );
    expect(state.handleBack(), isTrue);
    await tester.pumpAndSettle();

    expect(inHeader(Icons.archive_outlined), findsNothing);
    expect(inHeader(Icons.delete_outline), findsNothing);
    expect(find.byType(PresetBlockRow), findsOneWidget);
  });

  testWidgets('delete removes the open block and returns to the list', (
    tester,
  ) async {
    await pumpEditor(tester, presetWith([block('a'), block('b')]));
    await openBlock(tester);

    await tester.tap(inHeader(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.byType(PresetBlockRow), findsOneWidget);
    expect(inHeader(Icons.delete_outline), findsNothing);
    await flushSave(tester);
    expect(_StubPresetList.saved.last.blocks.map((b) => b.id), ['b']);
  });

  testWidgets('stash puts the open block away and returns to the list', (
    tester,
  ) async {
    await pumpEditor(tester, presetWith([block('a'), block('b')]));
    await openBlock(tester);

    await tester.tap(inHeader(Icons.archive_outlined));
    await tester.pumpAndSettle();

    // The block is still in the preset, just not in the list any more.
    expect(find.byType(PresetBlockRow), findsOneWidget);
    await flushSave(tester);
    final blocks = _StubPresetList.saved.last.blocks;
    expect(blocks.map((b) => b.id), ['a', 'b']);
    expect(blocks.firstWhere((b) => b.id == 'a').isStashed, isTrue);
  });

  testWidgets('a block opened out of the stash offers to restore it instead', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      presetWith([block('a'), block('b', stashed: true)]),
    );

    // Open the stashed block the way the reader does: through the stash drawer
    // on the dashboard card. Only "a" has a row, so "b" is unambiguous.
    await tester.tap(find.byType(PresetUtilButton).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('b'));
    await tester.pumpAndSettle();

    // The one button points the other way for a block that is already away.
    expect(inHeader(Icons.unarchive_outlined), findsOneWidget);
    expect(inHeader(Icons.archive_outlined), findsNothing);

    await tester.tap(inHeader(Icons.unarchive_outlined));
    await tester.pumpAndSettle();

    expect(find.byType(PresetBlockRow), findsNWidgets(2));
    await flushSave(tester);
    expect(
      _StubPresetList.saved.last.blocks.every((b) => !b.isStashed),
      isTrue,
    );
  });
}
