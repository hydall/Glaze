import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/shell/desktop/desktop_window_geometry.dart';

/// Hosts one [DesktopWindowGeometry] whose rect is owned by the test, the way
/// the window manager owns it in the app.
class _Host extends StatefulWidget {
  final Rect initial;

  const _Host({required this.initial});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late Rect rect = widget.initial;
  int maximizeToggles = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            DesktopWindowGeometry(
              rect: rect,
              bounds: constraints.biggest,
              onChanged: (next) => setState(() => rect = next),
              onToggleMaximize: () => maximizeToggles++,
              child: const Column(
                children: [
                  DesktopWindowMoveArea(
                    child: SizedBox(
                      key: Key('title'),
                      height: 48,
                      width: double.infinity,
                      child: ColoredBox(color: Colors.blue),
                    ),
                  ),
                  Expanded(child: ColoredBox(color: Colors.white)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  const initial = Rect.fromLTWH(100, 100, 500, 400);

  Future<_HostState> pumpHost(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const _Host(initial: initial));
    return tester.state<_HostState>(find.byType(_Host));
  }

  testWidgets('dragging the title bar moves the window', (tester) async {
    final host = await pumpHost(tester);

    await tester.drag(find.byKey(const Key('title')), const Offset(120, 60));
    await tester.pumpAndSettle();

    expect(host.rect.size, initial.size);
    // The drag slop is eaten before the pan starts; allow for it.
    expect(host.rect.left, closeTo(220, 20));
    expect(host.rect.top, closeTo(160, 20));
  });

  testWidgets('dragging the bottom-right corner resizes the window', (
    tester,
  ) async {
    final host = await pumpHost(tester);

    final gesture = await tester.startGesture(initial.bottomRight);
    await gesture.moveBy(const Offset(20, 20));
    await gesture.moveBy(const Offset(80, 60));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(host.rect.topLeft, initial.topLeft);
    expect(host.rect.width, closeTo(600, 20));
    expect(host.rect.height, closeTo(480, 20));
  });

  testWidgets('double-clicking the title bar toggles maximize', (
    tester,
  ) async {
    final host = await pumpHost(tester);

    await tester.tap(find.byKey(const Key('title')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('title')));
    await tester.pumpAndSettle();

    expect(host.maximizeToggles, 1);
  });
}
