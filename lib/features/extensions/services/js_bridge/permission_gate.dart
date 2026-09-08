import 'js_bridge_context.dart';

void requireBridgeCapability(
  PermissionCheck permissionCheck,
  String capabilityId,
) {
  if (!permissionCheck(capabilityId)) {
    throw StateError('Permission denied: $capabilityId');
  }
}
