import 'package:flutter_riverpod/legacy.dart';

class MemoryActivityState {
  final String sessionId;
  final String? messageId;
  final Map<String, dynamic> diagnostics;
  final int updatedAtMillis;

  const MemoryActivityState({
    required this.sessionId,
    this.messageId,
    required this.diagnostics,
    required this.updatedAtMillis,
  });

  bool get hasDiagnostics =>
      (diagnostics['totalCandidates'] as int? ?? 0) > 0 ||
      (diagnostics['selectedCount'] as int? ?? 0) > 0;
}

final lastMemoryActivityProvider =
    StateProvider.family<MemoryActivityState?, String>((ref, _) => null);
