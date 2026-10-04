import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_repo.dart';
import 'package:glaze_flutter/core/navigation/rewrite_review_navigation.dart';
import 'package:glaze_flutter/core/services/generation_notification_service.dart';

RewriteJobRow _job({String charId = 'char-1', String sessionId = 'session-1'}) {
  return RewriteJobRow(
    id: 'job-1',
    chatSessionId: sessionId,
    characterId: charId,
    status: 'pendingReview',
    requestJson: '{}',
    basisRevision: 1,
    basisRevisionHash: 'basis',
    canonStamp: 'canon',
    version: 1,
    appliedCharacterRevision: 0,
    appliedCharacterRevisionHash: '',
    createdAt: 1,
    updatedAt: 1,
  );
}

void main() {
  const policy = AutomaticRewriteReviewNavigationPolicy();
  const authority = ActiveChatContext(
    charId: 'char-1',
    sessionId: 'session-1',
    revision: 7,
  );

  test(
    'policy permits only exact persisted result for unchanged authority',
    () {
      final target = policy.resolve(
        outcome: CardEvolutionFinalizeOutcome('persisted', _job()),
        capturedAuthority: authority,
        currentAuthority: authority,
      );

      expect(target?.charId, 'char-1');
      expect(target?.jobId, 'job-1');
    },
  );

  test('policy rejects non-exact outcomes and stale authority revisions', () {
    expect(
      policy.resolve(
        outcome: CardEvolutionFinalizeOutcome('alreadyCompleted', _job()),
        capturedAuthority: authority,
        currentAuthority: authority,
      ),
      isNull,
    );
    expect(
      policy.resolve(
        outcome: CardEvolutionFinalizeOutcome('persisted', _job()),
        capturedAuthority: authority,
        currentAuthority: const ActiveChatContext(
          charId: 'char-1',
          sessionId: 'session-1',
          revision: 8,
        ),
      ),
      isNull,
    );
  });

  test('intent provider emits a monotonic sequence and encoded location', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(
      rewriteReviewNavigationIntentProvider.notifier,
    );

    notifier.emit(
      charId: 'char / one',
      sessionId: 'session-1',
      jobId: 'job/one',
      authorityRevision: 7,
    );
    final first = container.read(rewriteReviewNavigationIntentProvider)!;
    notifier.emit(
      charId: 'char / one',
      sessionId: 'session-1',
      jobId: 'job/one',
      authorityRevision: 7,
    );
    final second = container.read(rewriteReviewNavigationIntentProvider)!;

    expect(first.sequence, 1);
    expect(second.sequence, 2);
    expect(second.location, '/character/char%20%2F%20one/rewrite/job%2Fone');
  });
}
