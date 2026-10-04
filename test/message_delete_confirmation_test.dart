import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/studio_feature_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/message_actions.dart';
import 'package:glaze_flutter/features/chat/widgets/message_delete_confirmation.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';

/// Localization is intentionally not loaded: `.tr()` falls back to the key, so
/// these tests assert on the key strings the sheet requests.
class _StubSettings extends AppSettingsNotifier {
  _StubSettings(this.value);

  final AppSettings value;

  @override
  Future<AppSettings> build() async => value;
}

Future<void> _pumpButton(
  WidgetTester tester, {
  required AppSettings settings,
  required Future<bool> Function(BuildContext, WidgetRef) onPressed,
  required void Function(bool) onResult,
  bool agentsActive = false,
  List<Override> extraOverrides = const [],
}) async {
  await tester.binding.setSurfaceSize(const Size(412, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWith(() => _StubSettings(settings)),
      studioFeatureSettledProvider.overrideWith((ref) => agentsActive),
      ...extraOverrides,
    ],
  );
  addTearDown(container.dispose);
  // Resolve the provider up front so reading it synchronously in the test
  // callback sees the loaded value instead of AsyncLoading.
  await container.read(appSettingsProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Center(
              child: ElevatedButton(
                onPressed: () async => onResult(await onPressed(context, ref)),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('plain chat warns only about the messages themselves',
      (tester) async {
    bool? result;
    await _pumpButton(
      tester,
      settings: const AppSettings(),
      onPressed: (context, ref) => confirmMessageDeletion(context, ref),
      onResult: (value) => result = value,
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('delete_messages_title'), findsOneWidget);
    expect(
      find.textContaining('delete_messages_warning_base'),
      findsOneWidget,
    );
    expect(
      find.textContaining('delete_messages_warning_agents'),
      findsNothing,
    );
    expect(
      find.textContaining('delete_messages_warning_memory'),
      findsNothing,
    );
    expect(
      find.textContaining('delete_messages_warning_confirm'),
      findsOneWidget,
    );
    expect(find.text('delete_messages_confirm'), findsOneWidget);
    expect(find.text('delete_messages_cancel'), findsOneWidget);

    await tester.tap(find.text('delete_messages_cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('an agentic preset adds the agents sentence', (tester) async {
    await _pumpButton(
      tester,
      settings: const AppSettings(),
      agentsActive: true,
      onPressed: (context, ref) => confirmMessageDeletion(context, ref),
      onResult: (_) {},
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('delete_messages_warning_agents'),
      findsOneWidget,
    );
  });

  testWidgets('an enabled MemoryBook adds the memory sentence', (tester) async {
    await _pumpButton(
      tester,
      settings: const AppSettings(),
      onPressed: (context, ref) =>
          confirmMessageDeletion(context, ref, sessionId: 's1'),
      onResult: (_) {},
      extraOverrides: [
        memoryBookProvider('s1').overrideWith(
          (ref) async => const MemoryBook(id: 'memorybook_s1', sessionId: 's1'),
        ),
      ],
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('delete_messages_warning_memory'),
      findsOneWidget,
    );
  });

  testWidgets('confirming returns true', (tester) async {
    bool? result;
    await _pumpButton(
      tester,
      settings: const AppSettings(),
      onPressed: (context, ref) => confirmMessageDeletion(context, ref),
      onResult: (value) => result = value,
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('delete_messages_confirm'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('setting off deletes without a sheet', (tester) async {
    bool? result;
    await _pumpButton(
      tester,
      settings: const AppSettings(confirmMessageDelete: false),
      onPressed: (context, ref) => confirmMessageDeletion(context, ref),
      onResult: (value) => result = value,
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('delete_messages_title'), findsNothing);
    expect(result, isTrue);
  });

  testWidgets('message context menu opens the confirmation', (tester) async {
    await _pumpButton(
      tester,
      settings: const AppSettings(),
      onPressed: (context, ref) {
        showMessageContextMenu(
          context: context,
          ref: ref,
          charId: 'c1',
          sessionId: null,
          content: 'body',
          messageIndex: 1,
          messageId: 'm1',
          isUser: true,
          isTyping: false,
          isError: false,
          isLast: false,
          isGenerating: false,
          isHidden: false,
          canDeleteSwipe: false,
          canDeleteAgentSwipe: false,
        );
        return Future<bool>.value(false);
      },
      onResult: (_) {},
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('delete_messages_title'), findsOneWidget);
  });
}
