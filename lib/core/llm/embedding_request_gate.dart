import 'dart:async';
import 'dart:collection';

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

/// Spaces all embedding HTTP requests across service instances.
///
/// Requests wait in two FIFO queues and one is let through per interval.
/// Foreground requests (a query embedding the current generation is waiting
/// on) always go before background indexing, so a backlog of indexing work
/// never delays a reply. A request is only charged an interval once it is
/// let through: a cancelled waiter leaves its queue and frees its turn.
class EmbeddingRequestRateLimiter {
  EmbeddingRequestRateLimiter._();

  static DateTime? _lastGrant;
  static final Queue<_RateWaiter> _foreground = Queue();
  static final Queue<_RateWaiter> _background = Queue();
  static Timer? _timer;

  static Future<void> acquire(
    int requestsPerMinute,
    CancelToken token, {
    bool foreground = false,
  }) {
    if (token.isCancelled) return Future.error(token.cancelError!);

    final safeLimit = requestsPerMinute > 0 ? requestsPerMinute : 50;
    final waiter = _RateWaiter(
      Duration(
        microseconds: (Duration.microsecondsPerMinute / safeLimit).ceil(),
      ),
    );
    final queue = foreground ? _foreground : _background;
    queue.add(waiter);
    token.whenCancel.then((_) {
      if (waiter.completer.isCompleted) return;
      queue.remove(waiter);
      waiter.completer.completeError(token.cancelError!);
      _pump();
    });
    _pump();
    return waiter.completer.future;
  }

  static void _pump() {
    _timer?.cancel();
    _timer = null;
    while (true) {
      final queue = _foreground.isNotEmpty ? _foreground : _background;
      if (queue.isEmpty) return;
      final head = queue.first;
      final now = DateTime.now();
      final due = _lastGrant?.add(head.interval);
      if (due != null && due.isAfter(now)) {
        _timer = Timer(due.difference(now), _pump);
        return;
      }
      queue.removeFirst();
      _lastGrant = now;
      head.completer.complete();
    }
  }

  static void resetForTesting() {
    _timer?.cancel();
    _timer = null;
    _lastGrant = null;
    _foreground.clear();
    _background.clear();
  }
}

class _RateWaiter {
  _RateWaiter(this.interval);

  final Duration interval;
  final Completer<void> completer = Completer<void>();
}
