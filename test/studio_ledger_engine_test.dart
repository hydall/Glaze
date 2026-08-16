import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/services/stages/ledger_stage.dart';

void main() {
  test('Card Rewriter controls automatic reconciliation', () {
    expect(
      shouldRunAutomaticLedgerReconciliation(
        cardRewriterEnabled: false,
        isManualRerun: false,
      ),
      isFalse,
    );
    expect(
      shouldRunAutomaticLedgerReconciliation(
        cardRewriterEnabled: true,
        isManualRerun: false,
      ),
      isTrue,
    );
  });

  test('manual rerun never starts automatic reconciliation', () {
    expect(
      shouldRunAutomaticLedgerReconciliation(
        cardRewriterEnabled: true,
        isManualRerun: true,
      ),
      isFalse,
    );
  });
}
