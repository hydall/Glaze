import 'dart:async';

import '../js_bridge_context.dart';

class PromptInjectionHandler {
  const PromptInjectionHandler();

  FutureOr<Map<String, dynamic>> injectPrompt(JsBridgeContext bridge) {
    final id = bridge.params['id'];
    if (id is! String || id.trim().isEmpty) {
      throw ArgumentError('injectPrompt id is required');
    }
    final content = bridge.params['content'];
    if (content is! String || content.trim().isEmpty) {
      throw ArgumentError('injectPrompt content is required');
    }
    final handler = bridge.injectPrompt;
    return handler(
      id,
      content,
      asBridgeMap(bridge.params['options']),
      bridge.context,
    );
  }

  FutureOr<Map<String, dynamic>> uninjectPrompt(JsBridgeContext bridge) {
    final id = bridge.params['id'];
    if (id is! String || id.trim().isEmpty) {
      throw ArgumentError('uninjectPrompt id is required');
    }
    final handler = bridge.uninjectPrompt;
    return handler(id, bridge.context);
  }
}
