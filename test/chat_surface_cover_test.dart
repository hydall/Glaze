import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_webview_surface.dart';

/// The cover over the chat surface goes up at once and comes down with a
/// fade, so a chat that has just painted settles in instead of popping up
/// under a spinner that vanished too early.
void main() {
  Widget host(bool visible) => Directionality(
    textDirection: TextDirection.ltr,
    child: ChatSurfaceCover(
      visible: visible,
      child: const SizedBox.expand(key: Key('cover')),
    ),
  );

  testWidgets('up at once, down with a fade, then gone', (tester) async {
    await tester.pumpWidget(host(true));
    expect(find.byKey(const Key('cover')), findsOneWidget);
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );

    await tester.pumpWidget(host(false));
    await tester.pump();
    // Still there, fading: the page underneath is what the reader sees next.
    expect(find.byKey(const Key('cover')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 140));
    final midway = tester
        .widget<FadeTransition>(find.byType(FadeTransition))
        .opacity
        .value;
    expect(midway, greaterThan(0));
    expect(midway, lessThan(1));

    await tester.pump(ChatSurfaceCover.fade);
    await tester.pump();
    expect(find.byKey(const Key('cover')), findsNothing);
  });

  testWidgets('raised again mid-fade, it stays', (tester) async {
    await tester.pumpWidget(host(true));
    await tester.pumpWidget(host(false));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(host(true));
    await tester.pump(ChatSurfaceCover.fade);
    await tester.pump();

    expect(find.byKey(const Key('cover')), findsOneWidget);
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
  });

  testWidgets('never takes a touch', (tester) async {
    await tester.pumpWidget(host(true));
    expect(find.byType(IgnorePointer), findsOneWidget);
  });
}
