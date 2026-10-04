import 'package:dio/dio.dart';

class EmbeddingRequestGate {
  EmbeddingRequestGate._();

  static bool _enabled = true;
  static final Set<CancelToken> _activeTokens = {};

  static void setEnabled(bool enabled) {
    _enabled = enabled;
    if (enabled) return;
    for (final token in _activeTokens.toList()) {
      token.cancel('Embeddings disabled');
    }
    _activeTokens.clear();
  }

  static CancelToken beginRequest(CancelToken? parent) {
    final token = CancelToken();
    if (!_enabled) {
      token.cancel('Embeddings disabled');
      return token;
    }
    _activeTokens.add(token);
    parent?.whenCancel.then((_) => token.cancel(parent.cancelError));
    return token;
  }

  static void endRequest(CancelToken token) {
    _activeTokens.remove(token);
  }
}

/// Spaces all embedding HTTP requests across service instances. Reserving the
/// next slot synchronously keeps concurrent callers from starting together.
class EmbeddingRequestRateLimiter {
  EmbeddingRequestRateLimiter._();

  static DateTime? _nextSlot;

  static Future<void> acquire(int requestsPerMinute, CancelToken token) async {
    if (token.isCancelled) throw token.cancelError!;

    final safeLimit = requestsPerMinute > 0 ? requestsPerMinute : 50;
    final interval = Duration(
      microseconds: (Duration.microsecondsPerMinute / safeLimit).ceil(),
    );
    final now = DateTime.now();
    final slot = _nextSlot != null && _nextSlot!.isAfter(now)
        ? _nextSlot!
        : now;
    _nextSlot = slot.add(interval);

    final wait = slot.difference(now);
    if (wait > Duration.zero) {
      await Future.any<void>([
        Future<void>.delayed(wait),
        token.whenCancel.then<void>((_) {}),
      ]);
    }
    if (token.isCancelled) throw token.cancelError!;
  }

  static void resetForTesting() => _nextSlot = null;
}
