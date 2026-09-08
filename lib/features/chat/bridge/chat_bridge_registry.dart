import 'package:flutter_riverpod/legacy.dart';

import 'chat_bridge_controller.dart';

/// Registry that maps charId → ChatBridgeController.
///
/// The chat WebView widget registers its bridge controller here after
/// creation so that services (ExtensionPostGenService) can call
/// runJsBlock without a direct dependency on the widget tree.
///
/// The controller is nullable — if the WebView is not mounted the
/// JS runner block is skipped with an error status.
final chatBridgeRegistryProvider =
    StateProvider.family<ChatBridgeController?, String>((ref, charId) => null);
