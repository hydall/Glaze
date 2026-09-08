import 'trigger_mode.dart';

/// Result of a JS-side `glaze.triggerGeneration(...)` call as resolved by
/// GenerationDispatcher. Serialized back to the bridge as a plain map.
sealed class TriggerResult {
  const TriggerResult();

  bool get accepted;

  /// Stable lowercase identifier, used in JS error codes and debug logs.
  String get code;

  /// Human-readable message — safe to expose to JS.
  String get message;

  /// Convert to a plain map suitable for `BridgeResult.ok(TriggerResult.asMap)`.
  Map<String, dynamic> toMap();
}

class TriggerAccepted extends TriggerResult {
  const TriggerAccepted({required this.mode, this.reason});

  @override
  bool get accepted => true;

  @override
  String get code => 'accepted';

  @override
  String get message => 'triggered generation';

  final TriggerMode mode;
  final String? reason;

  @override
  Map<String, dynamic> toMap() => {
    'accepted': true,
    'mode': mode.name,
    if (reason != null) 'reason': reason,
  };
}

class TriggerBusy extends TriggerResult {
  const TriggerBusy({required this.busyKind, required this.mode});

  @override
  bool get accepted => false;

  @override
  String get code => busyKind == 'memory_draft' ? 'memory_draft_busy' : 'chat_busy';

  @override
  String get message => busyKind == 'memory_draft'
      ? 'A memory draft is being generated for this session; abort it before triggering a new chat generation.'
      : 'Chat generation is already active for this character.';

  /// Either `'chat'` or `'memory_draft'`.
  final String busyKind;
  final TriggerMode mode;

  @override
  Map<String, dynamic> toMap() => {
    'accepted': false,
    'busy': busyKind,
    'mode': mode.name,
  };
}

class TriggerNoSession extends TriggerResult {
  const TriggerNoSession({required this.mode});

  @override
  bool get accepted => false;

  @override
  String get code => 'no_session';

  @override
  String get message => 'No active chat session is available for this character.';

  final TriggerMode mode;

  @override
  Map<String, dynamic> toMap() => {'accepted': false, 'reason': 'no_session', 'mode': mode.name};
}

class TriggerError extends TriggerResult {
  const TriggerError({required this.message, required this.mode});

  @override
  bool get accepted => false;

  @override
  String get code => 'bridge_error';

  @override
  final String message;

  final TriggerMode mode;

  @override
  Map<String, dynamic> toMap() => {'accepted': false, 'reason': 'error', 'message': message, 'mode': mode.name};
}
