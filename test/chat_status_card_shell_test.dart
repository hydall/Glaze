import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/widgets/chat_status_card_shell.dart';
import 'package:glaze_flutter/shared/widgets/glaze_spinner.dart';

void main() {
  testWidgets('renders the shared decoration and spinner/action slots', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatStatusCardShell(
            label: 'Working',
            icon: Icons.sync,
            accent: Colors.orange,
            showSpinner: true,
            action: IconButton(
              onPressed: () {},
              tooltip: 'Stop work',
              icon: const Icon(Icons.stop_circle_outlined),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Working'), findsOneWidget);
    expect(find.byType(GlazeSpinner), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsNothing);
    expect(find.byTooltip('Stop work'), findsOneWidget);
    expect(
      tester.getSize(find.byType(GlazeSpinner)),
      const Size.square(18),
    );

    final container = tester.widget<Container>(
      find.ancestor(of: find.text('Working'), matching: find.byType(Container)),
    );
    expect(
      container.padding,
      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(14));
    expect(
      decoration.border,
      Border.all(color: Colors.orange.withValues(alpha: 0.35)),
    );
    expect(decoration.boxShadow, hasLength(1));
    expect(decoration.boxShadow!.single.blurRadius, 18);
    expect(decoration.boxShadow!.single.offset, const Offset(0, 8));
  });

  testWidgets('renders the icon slot without an action', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatStatusCardShell(
            label: 'Complete',
            icon: Icons.check_circle_outline,
            accent: Colors.green,
            showSpinner: false,
          ),
        ),
      ),
    );

    expect(find.text('Complete'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byType(GlazeSpinner), findsNothing);

    final text = tester.widget<Text>(find.text('Complete'));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(text.style!.fontWeight, FontWeight.w600);
  });
}
