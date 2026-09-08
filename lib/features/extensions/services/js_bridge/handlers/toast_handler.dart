import '../js_bridge_context.dart';

class ToastHandler {
  const ToastHandler();

  bool showToast(JsBridgeContext bridge) {
    final message = bridge.params['message'];
    if (message != null && message is! String) {
      throw ArgumentError('showToast message must be a string');
    }
    final options = asBridgeMap(bridge.params['options']);
    final handler = bridge.showToast;
    handler(message as String?, {...options, '_context': bridge.context});
    return true;
  }
}
