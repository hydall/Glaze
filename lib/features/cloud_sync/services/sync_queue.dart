import 'dart:math';

class SyncQueue {
  static const _maxRetries = 3;
  static const _baseDelayMs = 1000;
  static const _maxDelayMs = 30000;

  int _pendingCount = 0;
  bool _isPaused = false;
  bool _isAborted = false;

  int get pendingCount => _pendingCount;

  Future<T> enqueue<T>(Future<T> Function() operation, {String? label}) async {
    while (_isPaused) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    if (_isAborted) throw Exception('Sync queue aborted');

    _pendingCount++;
    try {
      return await _retryWithBackoff(operation, label);
    } finally {
      _pendingCount--;
    }
  }

  Future<({List<T> results, List<Object> errors})> enqueueAll<T>(
    List<Future<T> Function()> tasks, {
    int concurrency = 3,
    int delayMs = 300,
  }) async {
    final results = <int, T>{};
    final errors = <Object>[];
    var index = 0;

    Future<void> worker() async {
      while (index < tasks.length) {
        if (_isAborted) throw Exception('Sync queue aborted');
        while (_isPaused) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final i = index++;
        if (i >= tasks.length) break;
        try {
          final result = await enqueue(tasks[i]);
          results[i] = result;
        } catch (e) {
          errors.add(e);
        }
        if (delayMs > 0 && index < tasks.length) {
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
      }
    }

    final workers = List.generate(
      tasks.length.clamp(0, concurrency),
      (_) => worker(),
    );
    await Future.wait(workers);

    final sortedKeys = results.keys.toList()..sort();
    final sortedResults = sortedKeys.map((k) => results[k] as T).toList();
    return (results: sortedResults, errors: errors);
  }

  Future<T> _retryWithBackoff<T>(
    Future<T> Function() operation,
    String? label,
  ) async {
    var attempt = 0;
    while (true) {
      try {
        if (_isAborted) throw Exception('Sync queue aborted');
        return await operation();
      } catch (e) {
        attempt++;
        if (attempt >= _maxRetries || !_isRetryableError(e)) {
          rethrow;
        }
        final delay = _calculateDelay(attempt);
        await Future<void>.delayed(Duration(milliseconds: delay));
      }
    }
  }

  int _calculateDelay(int attempt) {
    final exponential = _baseDelayMs * (1 << (attempt - 1));
    final capped = exponential.clamp(0, _maxDelayMs);
    final jitter = Random().nextInt(1000) - 500;
    return (capped + jitter).clamp(0, _maxDelayMs);
  }

  bool _isRetryableError(dynamic e) {
    final msg = e.toString();
    if (msg.contains('429')) return true;
    if (msg.contains('5') && RegExp(r'5\d\d').hasMatch(msg)) return true;
    if (msg.contains('SocketException') || msg.contains('TimeoutException')) {
      return true;
    }
    if (msg.contains('HttpException') || msg.contains('Connection closed')) {
      return true;
    }
    if (msg.contains('Sync queue aborted')) return false;
    if (msg.contains('4') && RegExp(r'4\d\d').hasMatch(msg)) return false;
    return false;
  }

  void pause() => _isPaused = true;
  void resume() => _isPaused = false;
  void abort() => _isAborted = true;
  void reset() {
    _isPaused = false;
    _isAborted = false;
    _pendingCount = 0;
  }
}

class SyncQueueAggregateError implements Exception {
  final List<Object> errors;
  SyncQueueAggregateError(this.errors);

  @override
  String toString() {
    final first = errors.first.toString();
    if (errors.length == 1) return first;
    return '$first (+${errors.length - 1} more errors)';
  }
}
