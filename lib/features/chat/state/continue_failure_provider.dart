import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

/// One failed `continueMessage()` run. A continuation never writes an error
/// swipe or an error bubble (INV-CM4), so this notice is the only surface the
/// failure has: `ContinueFailureListener` turns it into the red
/// `Continue Failed` toast.
class ContinueFailureNotice {
  final String charId;
  final String? sessionId;

  /// Formatted transport/pipeline error. Kept for diagnostics — the toast
  /// itself stays a fixed short label so it cannot overflow with a stack of
  /// provider JSON.
  final String error;

  /// Distinguishes two consecutive failures carrying the same text, which the
  /// listener would otherwise skip as an unchanged state.
  final int nonce;

  const ContinueFailureNotice({
    required this.charId,
    required this.sessionId,
    required this.error,
    required this.nonce,
  });
}

final continueFailureProvider = StateProvider<ContinueFailureNotice?>(
  (ref) => null,
);

/// Monotonic counter behind [ContinueFailureNotice.nonce].
int _continueFailureNonce = 0;

int nextContinueFailureNonce() => ++_continueFailureNonce;

/// Publish a failed continuation. Safe to call from a disposed container —
/// a failure that outlives the chat has nothing left to notify.
void reportContinueFailure(
  Ref ref, {
  required String charId,
  required String? sessionId,
  required String error,
}) {
  if (!ref.mounted) return;
  debugPrint('[continue] failed char=$charId session=$sessionId: $error');
  ref.read(continueFailureProvider.notifier).state = ContinueFailureNotice(
    charId: charId,
    sessionId: sessionId,
    error: error,
    nonce: nextContinueFailureNonce(),
  );
}
