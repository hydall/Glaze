import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'chat_bridge_controller.dart';

/// Outgoing TTS commands: the voice pills under messages and the WebView's
/// audio decoder.
class TtsBridgeCommands {
  final ChatBridgeController _host;

  TtsBridgeCommands(this._host);

  /// Replaces every pill: on/off and the full id → state map.
  Future<void> configure({
    required bool enabled,
    required Map<String, Map<String, dynamic>> states,
  }) => _host.callJs(
    'ttsConfigure',
    jsonEncode({'enabled': enabled, 'states': states}),
  );

  /// Updates only the given pills.
  Future<void> patch(Map<String, Map<String, dynamic>> states) {
    if (states.isEmpty) return Future.value();
    return _host.callJs('ttsPatch', jsonEncode(states));
  }

  Future<void> progress(String messageId, int positionMs, int? durationMs) =>
      _host.callJs(
        'ttsProgress',
        jsonEncode({'id': messageId, 'pos': positionMs, 'dur': durationMs}),
      );

  /// Duration and peaks of compressed audio, decoded by the WebView. Null
  /// when the page cannot decode it.
  Future<({int durationMs, List<double> peaks})?> decodePeaks(
    Uint8List bytes,
    String mime, {
    int buckets = 64,
  }) async {
    try {
      final result = await _host.callAsyncJs(
        'return await window.bridge.ttsDecodePeaks(b64, mime, n);',
        {'b64': base64Encode(bytes), 'mime': mime, 'n': buckets},
      );
      if (result is! Map) return null;
      final duration = result['durationMs'];
      final peaks = result['peaks'];
      if (duration is! num || peaks is! List) return null;
      return (
        durationMs: duration.toInt(),
        peaks: [for (final p in peaks) if (p is num) p.toDouble()],
      );
    } catch (e) {
      debugPrint('[TTS] WebView decode failed: $e');
      return null;
    }
  }
}
