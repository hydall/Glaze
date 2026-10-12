import 'plugin_settings_schema.dart';

/// Thrown when a `.tpg` package or its `manifest.json` is not acceptable.
class PluginManifestException implements Exception {
  const PluginManifestException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A manifest string that is either literal or a `{ "$t": "key" }` catalog
/// reference (Tavo manifest v2).
class PluginText {
  const PluginText.literal(String this.literal) : key = null;
  const PluginText.key(String this.key) : literal = null;

  final String? literal;
  final String? key;

  static PluginText? tryParse(Object? raw) {
    if (raw is String) return PluginText.literal(raw);
    if (raw is Map && raw.length == 1 && raw[r'$t'] is String) {
      return PluginText.key(raw[r'$t'] as String);
    }
    return null;
  }
}

enum PluginMountSurface { chat, messages }

/// Parsed `htmlFragments[].mount` (`/chat/body/end`,
/// `/messages/end?role=character&position=last`, …).
class PluginMount {
  const PluginMount({
    required this.surface,
    this.region = 'body',
    this.slot = 'end',
    this.role,
    this.position,
  });

  final PluginMountSurface surface;
  final String region;
  final String slot;
  final String? role;
  final String? position;

  static PluginMount parse(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !raw.startsWith('/')) {
      throw PluginManifestException('htmlFragments mount is invalid: $raw');
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      throw PluginManifestException('htmlFragments mount is invalid: $raw');
    }
    switch (segments.first) {
      case 'chat':
        if (segments.length == 1) {
          return const PluginMount(surface: PluginMountSurface.chat);
        }
        if (segments.length != 3 ||
            !const {'head', 'body'}.contains(segments[1]) ||
            !const {'start', 'end'}.contains(segments[2])) {
          throw PluginManifestException('htmlFragments mount is invalid: $raw');
        }
        return PluginMount(
          surface: PluginMountSurface.chat,
          region: segments[1],
          slot: segments[2],
        );
      case 'messages':
        final slot = segments.length > 1 ? segments[1] : 'end';
        final role = uri.queryParameters['role'];
        final position = uri.queryParameters['position'];
        if (segments.length > 2 ||
            !const {'start', 'end'}.contains(slot) ||
            (role != null && !const {'user', 'character'}.contains(role)) ||
            (position != null && !const {'first', 'last'}.contains(position))) {
          throw PluginManifestException('htmlFragments mount is invalid: $raw');
        }
        return PluginMount(
          surface: PluginMountSurface.messages,
          slot: slot,
          role: role,
          position: position,
        );
      default:
        throw PluginManifestException('htmlFragments mount is invalid: $raw');
    }
  }
}

class PluginAction {
  const PluginAction({
    required this.id,
    required this.label,
    this.icon,
    this.role = 'character',
  });

  final String id;
  final PluginText label;
  final String? icon;

  /// Last-message actions only: `character`, `user` or `any`.
  final String role;
}

class PluginFragment {
  const PluginFragment({
    required this.id,
    required this.src,
    required this.mount,
  });

  final String id;
  final String src;
  final PluginMount mount;
}

class PluginManifest {
  const PluginManifest({
    required this.specVersion,
    required this.id,
    required this.name,
    required this.version,
    required this.raw,
    this.entry,
    this.author,
    this.description,
    this.releaseNotes,
    this.defaultLocale,
    this.localeResources = const {},
    this.cover,
    this.minAppVersion,
    this.permissions = const [],
    this.inputActions = const [],
    this.sidebarActions = const [],
    this.lastMessageActions = const [],
    this.fragments = const [],
    this.settings = const [],
    this.hasFileProcessors = false,
  });

  final int specVersion;
  final String id;
  final PluginText name;
  final String version;
  final String? entry;
  final String? author;
  final PluginText? description;
  final PluginText? releaseNotes;
  final String? defaultLocale;
  final Map<String, String> localeResources;
  final String? cover;
  final String? minAppVersion;
  final List<String> permissions;
  final List<PluginAction> inputActions;
  final List<PluginAction> sidebarActions;
  final List<PluginAction> lastMessageActions;
  final List<PluginFragment> fragments;
  final List<PluginSettingField> settings;
  final bool hasFileProcessors;

  /// The manifest as read, kept for re-parsing on load.
  final Map<String, dynamic> raw;

  bool hasPermission(String permission) => permissions.contains(permission);
}
