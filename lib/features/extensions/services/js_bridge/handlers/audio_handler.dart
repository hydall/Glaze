import 'dart:async';

import '../js_bridge_context.dart';

class AudioHandler {
  const AudioHandler();

  FutureOr<void> playAudio(JsBridgeContext bridge) {
    final source = bridge.params['source'];
    if (source != null && source is! String) {
      throw ArgumentError('playAudio source must be a string');
    }
    final handler = bridge.playAudio;
    return handler(source as String?, asBridgeMap(bridge.params['options']));
  }
}
