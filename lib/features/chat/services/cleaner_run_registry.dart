import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final cleanerRunRegistryProvider = Provider<CleanerRunRegistry>(
  (_) => CleanerRunRegistry(),
);

class CleanerRunKey {
  final String sessionId;
  final String messageId;

  const CleanerRunKey({required this.sessionId, required this.messageId});

  @override
  bool operator ==(Object other) =>
      other is CleanerRunKey &&
      other.sessionId == sessionId &&
      other.messageId == messageId;

  @override
  int get hashCode => Object.hash(sessionId, messageId);
}

class CleanerRunLease {
  final CleanerRunRegistry _registry;
  final CleanerRunKey key;
  final Completer<void> _done = Completer<void>();
  final List<CancelToken> _cancelTokens = [];
  bool _cancelled = false;

  CleanerRunLease._(this._registry, this.key);

  bool get isCurrent => !_cancelled && _registry._runs[key] == this;
  bool get ownsSharedState => isCurrent && _registry._latest == this;
  bool get isCancelled => _cancelled;
  Future<void> get done => _done.future;

  void registerCancelToken(CancelToken token) {
    if (_cancelled || !isCurrent) {
      if (!token.isCancelled) token.cancel();
      return;
    }
    _cancelTokens.add(token);
  }

  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final token in _cancelTokens) {
      if (!token.isCancelled) token.cancel();
    }
  }

  void _complete() {
    if (!_done.isCompleted) _done.complete();
  }
}

class CleanerRunRegistry {
  final Map<CleanerRunKey, CleanerRunLease> _runs = {};
  CleanerRunLease? _latest;

  Future<void> run(
    CleanerRunKey key,
    Future<void> Function(CleanerRunLease lease) action,
  ) async {
    final previous = _runs[key];
    final lease = CleanerRunLease._(this, key);
    _runs[key] = lease;
    _latest = lease;
    previous?._cancel();

    try {
      if (previous != null) await previous.done;
      if (!lease.isCurrent) return;
      await action(lease);
    } finally {
      if (identical(_runs[key], lease)) _runs.remove(key);
      if (identical(_latest, lease)) _latest = null;
      lease._complete();
    }
  }
}
