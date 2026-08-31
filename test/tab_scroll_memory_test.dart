import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/widgets/tab_scroll_memory.dart';

/// Two tabs whose bodies are torn down and rebuilt from scratch on every
/// switch — the shape [TabScrollMemory] exists for.
class _TabsHarness extends StatefulWidget {
  const _TabsHarness({required this.memory});

  final TabScrollMemory memory;

  @override
  State<_TabsHarness> createState() => _TabsHarnessState();
}

class _TabsHarnessState extends State<_TabsHarness> {
  int tab = 0;
  int bodyRevision = 0;

  void switchTo(int next) {
    setState(() {
      widget.memory.switchTab(from: tab, to: next);
      tab = next;
    });
  }

  /// Replaces the current tab's body without changing tabs — what opening a
  /// folder inside "My Characters" does.
  void rebuildBody() => setState(() => bodyRevision++);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: PrimaryScrollController(
          controller: widget.memory.controllerFor(tab),
          automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
          child: ListView.builder(
            key: ValueKey('tab-$tab-$bodyRevision'),
            itemCount: 100,
            itemExtent: 50,
            itemBuilder: (_, i) => Text('tab $tab item $i'),
          ),
        ),
      ),
    );
  }
}

void main() {
  group('TabScrollMemory', () {
    testWidgets('each tab comes back at the offset it was left at', (
      tester,
    ) async {
      final memory = TabScrollMemory(tabCount: 2);
      addTearDown(memory.dispose);

      await tester.pumpWidget(_TabsHarness(memory: memory));
      final harness = tester.state<_TabsHarnessState>(
        find.byType(_TabsHarness),
      );

      memory.controllerFor(0).jumpTo(500);
      await tester.pump();

      // A tab opened for the first time starts at the top.
      harness.switchTo(1);
      await tester.pump();
      expect(memory.controllerFor(1).offset, 0);

      memory.controllerFor(1).jumpTo(300);
      await tester.pump();

      // Both tabs now re-open where they were left, in either direction.
      harness.switchTo(0);
      await tester.pump();
      expect(memory.controllerFor(0).offset, 500);

      harness.switchTo(1);
      await tester.pump();
      expect(memory.controllerFor(1).offset, 300);
    });

    testWidgets('a body rebuilt without a tab switch starts at the top', (
      tester,
    ) async {
      final memory = TabScrollMemory(tabCount: 2);
      addTearDown(memory.dispose);

      await tester.pumpWidget(_TabsHarness(memory: memory));
      final harness = tester.state<_TabsHarnessState>(
        find.byType(_TabsHarness),
      );

      memory.controllerFor(0).jumpTo(400);
      await tester.pump();

      harness.rebuildBody();
      await tester.pump();

      expect(memory.controllerFor(0).offset, 0);
    });
  });
}
