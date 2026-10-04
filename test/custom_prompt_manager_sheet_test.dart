import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:glaze_flutter/core/services/memory_prompt_presets.dart';
import 'package:glaze_flutter/features/chat/widgets/custom_prompt_manager_sheet.dart';

void main() {
  const custom = MemoryPromptPreset(
    key: 'custom_existing',
    label: 'Existing',
    prompt: 'Existing prompt',
  );

  Future<void> pumpManager(
    WidgetTester tester, {
    List<MemoryPromptPreset> prompts = const [],
    ValueChanged<List<MemoryPromptPreset>?>? onResult,
  }) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  final result =
                      await showModalBottomSheet<List<MemoryPromptPreset>>(
                        context: context,
                        builder: (_) =>
                            CustomPromptManagerSheet(customPrompts: prompts),
                      );
                  onResult?.call(result);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('stock preset opens full selectable read-only preview', (
    tester,
  ) async {
    await pumpManager(tester);
    await tester.tap(
      find.byKey(const Key('memory_prompt_builtin_detailed_beats')),
    );
    await tester.pumpAndSettle();

    final preview = tester.widget<SelectableText>(
      find.byKey(const Key('memory_prompt_preview_text')),
    );
    expect(preview.data, MemoryPromptPresets.builtIn.first.prompt);
    expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
    expect(find.byKey(const Key('memory_prompt_copy_as_new')), findsOneWidget);
  });

  testWidgets('copy-as-new is prefilled and returns a new custom key', (
    tester,
  ) async {
    List<MemoryPromptPreset>? result;
    await pumpManager(tester, onResult: (value) => result = value);
    await tester.tap(
      find.byKey(const Key('memory_prompt_builtin_detailed_beats')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory_prompt_copy_as_new')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('memory_prompt_body_field')))
          .controller!
          .text,
      MemoryPromptPresets.builtIn.first.prompt,
    );
    await tester.enterText(
      find.byKey(const Key('memory_prompt_name_field')),
      'Copied preset',
    );
    await tester.tap(find.byKey(const Key('memory_prompt_editor_save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory_prompt_manager_save')));
    await tester.pumpAndSettle();

    expect(result, hasLength(1));
    expect(result!.single.key, startsWith('custom_'));
    expect(MemoryPromptPresets.isBuiltIn(result!.single.key), isFalse);
    expect(result!.single.prompt, MemoryPromptPresets.builtIn.first.prompt);
  });

  testWidgets(
    'custom preset can be edited and deleted and save returns result',
    (tester) async {
      List<MemoryPromptPreset>? result;
      await pumpManager(
        tester,
        prompts: const [custom],
        onResult: (value) => result = value,
      );
      await tester.tap(
        find.byKey(const Key('memory_prompt_edit_custom_existing')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('memory_prompt_name_field')),
        'Edited',
      );
      await tester.enterText(
        find.byKey(const Key('memory_prompt_body_field')),
        'Edited prompt',
      );
      await tester.tap(find.byKey(const Key('memory_prompt_editor_save')));
      await tester.pumpAndSettle();
      expect(find.text('Edited'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('memory_prompt_delete_custom_existing')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory_prompt_manager_save')));
      await tester.pumpAndSettle();
      expect(result, isEmpty);
    },
  );

  testWidgets('editor rejects an empty prompt', (tester) async {
    await pumpManager(tester, prompts: const [custom]);
    await tester.tap(
      find.byKey(const Key('memory_prompt_edit_custom_existing')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('memory_prompt_body_field')),
      '   ',
    );
    await tester.tap(find.byKey(const Key('memory_prompt_editor_save')));
    await tester.pump();
    expect(find.text('memory_prompt_required'), findsOneWidget);
  });

  testWidgets('manager save completes the typed route result contract', (
    tester,
  ) async {
    List<MemoryPromptPreset>? routeResult;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                routeResult =
                    await showModalBottomSheet<List<MemoryPromptPreset>>(
                      context: context,
                      builder: (_) => const CustomPromptManagerSheet(
                        customPrompts: [custom],
                      ),
                    );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('memory_prompt_manager_save')),
    );
    await tester.tap(find.byKey(const Key('memory_prompt_manager_save')));
    await tester.pumpAndSettle();

    expect(routeResult, const [custom]);
  });
}
