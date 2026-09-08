import 'dart:async';

import '../models/trigger_mode.dart';
import '../models/trigger_result.dart';
import 'generation_dispatcher.dart';

/// Typed bridge handler for `glaze.triggerGeneration({ mode, reason })`.
///
/// The handler never throws — every failure is converted into a
/// [TriggerResult] and serialized back to the JS SDK as a plain map
/// (see [toBridgeMap]). This keeps the error contract simple on the JS
/// side: the SDK throws on `ok: false`, otherwise it resolves to the
/// `result` field.
class TriggerGenerationHandler {
  TriggerGenerationHandler({required this.dispatcher, this.log});

  final GenerationDispatcher dispatcher;

  /// Optional log sink for diagnostics. When null, calls are silent.
  final void Function(String line)? log;

  /// Dispatch a trigger request.
  ///
  /// `params` is the JS-supplied options object (`{ mode?, reason? }`).
  /// `charId` is the resolved character id from bridge context — supplied
  /// by the caller because the JS side may not have access to it (headless
  /// engine). Pass `null` only when the bridge is global; the handler will
  /// then reject with a `no_session` [TriggerNoSession].
  ///
  /// Returns a plain map suitable for the bridge `result` payload.
  /// Validation errors are surfaced as [ArgumentError] so the bridge
  /// dispatcher can convert them into `invalid_request` error codes.
  Future<Map<String, dynamic>> handle({
    required String? charId,
    required Map<String, dynamic> params,
  }) async {
    final rawMode = params['mode'];
    if (rawMode != null && rawMode is! String) {
      throw ArgumentError('triggerGeneration mode must be a string');
    }
    final rawReason = params['reason'];
    String? reason;
    if (rawReason != null) {
      if (rawReason is! String) {
        throw ArgumentError('triggerGeneration reason must be a string');
      }
      reason = rawReason.isNotEmpty ? rawReason : null;
    }

    if (charId == null || charId.isEmpty) {
      return TriggerNoSession(mode: TriggerMode.parse(rawMode as String?))
          .toMap();
    }

    final result = await dispatcher.dispatch(
      charId: charId,
      rawMode: rawMode as String?,
      reason: reason,
    );
    log?.call('[TriggerGenerationHandler] charId=$charId result=${result.code}');
    return result.toMap();
  }
}
