import 'plugin_settings_schema.dart';

/// Thrown when a plugin package or its manifest is not acceptable.
class PluginManifestException implements Exception {
  const PluginManifestException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A manifest string that is either literal or a `{ "t": "key" }` reference
/// into the plugin's locale files.
class PluginText {
  const PluginText.literal(String this.literal) : key = null;
  const PluginText.key(String this.key) : literal = null;

  final String? literal;
  final String? key;

  static PluginText? tryParse(Object? raw) {
    if (raw is String) return PluginText.literal(raw);
    if (raw is Map && raw.length == 1 && raw['t'] is String) {
      return PluginText.key(raw['t'] as String);
    }
    return null;
  }

  Object toJson() => literal ?? {'t': key};
}

/// Manifest permissions. A bridged method whose permission the manifest does
/// not list is rejected.
abstract final class PluginPermission {
  static const composer = 'composer';
  static const messages = 'messages';
  static const variables = 'variables';
  static const files = 'files';
  static const generate = 'generate';
  static const images = 'images';
  static const library = 'library';
  static const network = 'network';

  static const all = {
    composer,
    messages,
    variables,
    files,
    generate,
    images,
    library,
    network,
  };
}

enum PluginPanelPlacement { chat, message }

/// Where a panel is shown. Chat panels float over the chat page; message
/// panels sit inside each matching message.
class PluginPanel {
  const PluginPanel({
    required this.id,
    required this.src,
    required this.placement,
    this.slot = 'end',
    this.role,
    this.position,
  });

  final String id;
  final String src;
  final PluginPanelPlacement placement;

  /// `start` or `end` of the chat page / message body.
  final String slot;

  /// Message panels only: `user` or `character`.
  final String? role;

  /// Message panels only: `first` or `last` message of the chat.
  final String? position;

  Map<String, Object?> toJson() => {
    'id': id,
    'src': src,
    'placement': placement.name,
    'slot': slot,
    if (role != null) 'role': role,
    if (position != null) 'position': position,
  };
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

  /// Message actions only: `character`, `user` or `any`.
  final String role;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label.toJson(),
    if (icon != null) 'icon': icon,
    'role': role,
  };
}

/// Turns attached files of the listed types into text for the model.
class PluginFileHandler {
  const PluginFileHandler({
    required this.id,
    this.extensions = const [],
    this.mimeTypes = const [],
    this.scripts = const [],
    this.icon,
  });

  final String id;
  final List<String> extensions;
  final List<String> mimeTypes;

  /// Scripts loaded only for this handler; empty means the handler is
  /// registered from `main`.
  final List<String> scripts;
  final String? icon;

  bool matches(String fileName, String? mimeType) {
    final dot = fileName.lastIndexOf('.');
    final ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
    return extensions.contains(ext) ||
        (mimeType != null && mimeTypes.contains(mimeType.toLowerCase()));
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'extensions': extensions,
    'mimeTypes': mimeTypes,
    'scripts': scripts,
    if (icon != null) 'icon': icon,
  };
}

/// A parsed `plugin.json`.
class PluginManifest {
  const PluginManifest({
    required this.format,
    required this.id,
    required this.name,
    required this.version,
    required this.raw,
    this.main,
    this.author,
    this.description,
    this.releaseNotes,
    this.defaultLocale,
    this.localeFiles = const {},
    this.icon,
    this.minGlazeVersion,
    this.compat,
    this.permissions = const [],
    this.hosts = const [],
    this.composerActions = const [],
    this.toolsActions = const [],
    this.messageActions = const [],
    this.panels = const [],
    this.fileHandlers = const [],
    this.settings = const [],
  });

  final int format;
  final String id;
  final PluginText name;
  final String version;
  final String? main;
  final String? author;
  final PluginText? description;
  final PluginText? releaseNotes;
  final String? defaultLocale;
  final Map<String, String> localeFiles;
  final String? icon;
  final String? minGlazeVersion;

  /// Set when the package was converted from another app's format; the
  /// runtime then also loads that app's script API (`tavo`).
  final String? compat;
  final List<String> permissions;

  /// Hosts the plugin says it needs (`example.com`, `*.example.com`); with
  /// the `network` permission, a fresh install may reach only these.
  final List<String> hosts;
  final List<PluginAction> composerActions;
  final List<PluginAction> toolsActions;
  final List<PluginAction> messageActions;
  final List<PluginPanel> panels;
  final List<PluginFileHandler> fileHandlers;
  final List<PluginSettingField> settings;

  /// The manifest as read.
  final Map<String, dynamic> raw;

  bool hasPermission(String permission) => permissions.contains(permission);
}

final RegExp _hostPattern = RegExp(
  r'^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$',
);

/// [raw] as a host rule (`example.com` or `*.example.com`, lower case), or
/// null when it is not one.
String? normalizePluginHost(String raw) {
  var host = raw.trim().toLowerCase();
  final uri = host.contains('://') ? Uri.tryParse(host) : null;
  if (uri != null) host = uri.host;
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  return host.isNotEmpty && host.length <= 253 && _hostPattern.hasMatch(host)
      ? host
      : null;
}

/// Whether [host] is covered by one of [rules]; `*.example.com` covers
/// subdomains of example.com, not example.com itself.
bool pluginHostAllowed(Iterable<String> rules, String host) {
  host = host.toLowerCase();
  for (final rule in rules) {
    if (rule.startsWith('*.')
        ? host.endsWith(rule.substring(1))
        : host == rule) {
      return true;
    }
  }
  return false;
}
