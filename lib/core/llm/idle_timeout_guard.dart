import 'dart:async';

import 'package:flutter/foundation.dart';

/// Idle-timeout helper for LLM streaming calls.
///
/// Mirrors [AgentStreamRunner]'s idle timeout pattern: the timer fires only
/// if the model emits NO output (text OR reasoning) within [timeoutMs]. Once
/// any chunk arrives, the timer is cancelled for good so a long (but
/// progressing) generation is never cut off mid-stream.
///
/// Usage:
/// ```dart
/// final guard = IdleTimeoutGuard(timeoutMs, () => completer.completeError(
///   TimeoutException('LLM timed out (idle) after ${timeoutMs}ms'),
/// ));
/// // ... on first chunk:
/// guard.cancel();
/// // ... on complete / error / dispose:
/// guard.dispose();
/// ```
class IdleTimeoutGuard {
  final int timeoutMs;
  final void Function() onIdleTimeout;
  Timer? _timer;
  bool _cancelled = false;

  IdleTimeoutGuard(this.timeoutMs, this.onIdleTimeout) {
    _start();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: timeoutMs), () {
      if (_cancelled) return;
      debugPrint(
        '[IdleTimeoutGuard] idle timeout fired after ${timeoutMs}ms '
        '(no chunks received)',
      );
      onIdleTimeout();
    });
  }

  /// Cancel the idle timer permanently — call on first chunk (text or
  /// reasoning). After this, only onComplete/onError/external cancel
  /// terminates the call.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Dispose any pending timer — call on completion, error, or dispose.
  void dispose() {
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
  }
}
