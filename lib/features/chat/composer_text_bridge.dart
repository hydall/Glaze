import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Programmatic access to the composer's text, for plugins (`tavo.input.*`).
///
/// The text controller is private to [ChatInputBar], which registers itself
/// here on mount — the same holder pattern as `ComposerActionBridge`.
class ComposerTextAccess {
  const ComposerTextAccess({
    required this.read,
    required this.write,
    required this.send,
  });

  final String Function() read;
  final void Function(String text) write;

  /// Sends whatever the composer holds through the normal send path.
  /// Resolves `true` once the message is accepted.
  final Future<bool> Function() send;
}

class ComposerTextBridge {
  ComposerTextAccess? _access;

  void register(ComposerTextAccess access) => _access = access;

  /// Identity-checked so a composer being replaced cannot drop its successor.
  void unregister(ComposerTextAccess access) {
    if (identical(_access, access)) _access = null;
  }

  ComposerTextAccess? get access => _access;
}

final composerTextBridgeProvider = Provider<ComposerTextBridge>(
  (ref) => ComposerTextBridge(),
);
