import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:glaze_flutter/features/cloud_sync/widgets/sync_sheet.dart';

void main() {
  const entry = SyncManifestEntry(
    type: 'tracker_value',
    id: 'session',
    path: '/tracker.json',
    updatedAt: 1,
    hash: 'hash',
  );
  const conflict = SyncConflict(
    key: 'tracker_value:session',
    type: 'tracker_value',
    id: 'session',
    localEntry: entry,
    cloudEntry: entry,
    name: 'Tracker values for a very long session name',
  );

  Future<void> pumpRow(WidgetTester tester, double width) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: SyncConflictRow(
                conflict: conflict,
                enabled: true,
                onLocal: () {},
                onCloud: () {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('narrow conflict row gives the name the full width', (
    tester,
  ) async {
    await pumpRow(tester, 320);

    expect(tester.takeException(), isNull);
    final nameRect = tester.getRect(
      find.byKey(const Key('sync-conflict-name')),
    );
    final firstButtonRect = tester.getRect(find.byType(TextButton).first);
    expect(nameRect.width, greaterThan(250));
    expect(nameRect.bottom, lessThanOrEqualTo(firstButtonRect.top));
  });

  testWidgets('wide conflict row keeps actions beside the name', (
    tester,
  ) async {
    await pumpRow(tester, 800);

    expect(tester.takeException(), isNull);
    final nameRect = tester.getRect(
      find.byKey(const Key('sync-conflict-name')),
    );
    final firstButtonRect = tester.getRect(find.byType(TextButton).first);
    expect(nameRect.center.dy, closeTo(firstButtonRect.center.dy, 0.1));
    expect(nameRect.right, lessThanOrEqualTo(firstButtonRect.left));
  });
}
