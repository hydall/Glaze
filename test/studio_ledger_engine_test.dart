import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/services/stages/ledger_stage.dart';

void main() {
  test('Studio Ledger controls automatic reconciliation', () {
    expect(
      shouldRunAutomaticLedgerReconciliation(
        ledgerEnabled: false,
        isManualRerun: false,
      ),
      isFalse,
    );
    expect(
      shouldRunAutomaticLedgerReconciliation(
        ledgerEnabled: true,
        isManualRerun: false,
      ),
      isTrue,
    );
  });

  test('manual rerun never starts automatic reconciliation', () {
    expect(
      shouldRunAutomaticLedgerReconciliation(
        ledgerEnabled: true,
        isManualRerun: true,
      ),
      isFalse,
    );
  });
}
