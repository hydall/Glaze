import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/llm/prompt/lorebook_vector_searcher.dart';
import 'package:glaze_flutter/features/chat/providers/prompt_build_providers.dart';
import 'package:glaze_flutter/features/chat/widgets/lorebook_vector_search_diagnostic_listener.dart';
import 'package:glaze_flutter/shared/widgets/glaze_toast.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(GlazeToast.hide);

  testWidgets('shows the vector search fallback error', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: LorebookVectorSearchDiagnosticListener(
            child: Overlay(
              key: toastOverlayKey,
              initialEntries: [
                OverlayEntry(builder: (_) => const SizedBox.expand()),
              ],
            ),
          ),
        ),
      ),
    );

    container
        .read(lorebookVectorSearchDiagnosticProvider.notifier)
        .state = LorebookVectorSearchDiagnostic(
      error: StateError('embedding failed'),
      stackTrace: StackTrace.current,
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(
      find.text('Vector search failed — try reindexing embeddings'),
      findsOneWidget,
    );
    GlazeToast.hide();
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
  });
}
