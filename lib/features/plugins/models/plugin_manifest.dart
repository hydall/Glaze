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

  /// The open chat: its messages, memory and events.
  static const messages = 'messages';

  /// The plugin's own variables: per chat, per message and global.
  static const variables = 'variables';

  /// The `shared` variables every plugin reads and writes together.
  static const variablesShared = 'variables.shared';
  static const files = 'files';
  static const generate = 'generate';
  static const images = 'images';
  static const network = 'network';

  /// The library, one permission per kind of item and what is done to it:
  /// `library.<read|create|update|delete>.<kind>`.
  static const charactersRead = 'library.read.characters';
  static const charactersCreate = 'library.create.characters';
  static const charactersUpdate = 'library.update.characters';
  static const charactersDelete = 'library.delete.characters';
  static const personasRead = 'library.read.personas';
  static const personasCreate = 'library.create.personas';
  static const personasUpdate = 'library.update.personas';
  static const personasDelete = 'library.delete.personas';
  static const presetsRead = 'library.read.presets';
  static const presetsCreate = 'library.create.presets';
  static const presetsUpdate = 'library.update.presets';
  static const presetsDelete = 'library.delete.presets';
  static const lorebooksRead = 'library.read.lorebooks';
  static const lorebooksCreate = 'library.create.lorebooks';
  static const lorebooksUpdate = 'library.update.lorebooks';
  static const lorebooksDelete = 'library.delete.lorebooks';
  static const regexRead = 'library.read.regex';
  static const regexCreate = 'library.create.regex';
  static const regexUpdate = 'library.update.regex';
  static const regexDelete = 'library.delete.regex';
  static const themesRead = 'library.read.themes';
  static const themesCreate = 'library.create.themes';
  static const themesUpdate = 'library.update.themes';
  static const themesDelete = 'library.delete.themes';

  /// Chats other than the open one, and creating or deleting chats.
  static const chatsRead = 'chats.read';
  static const chatsCreate = 'chats.create';
  static const chatsUpdate = 'chats.update';
  static const chatsDelete = 'chats.delete';

  /// Format 1 manifests written before the split; stands for all of
  /// [library] and [chats].
  static const legacyLibrary = 'library';

  /// Written before the library was split by kind; each stands for its
  /// action on every kind.
  static const legacyLibraryRead = 'library.read';
  static const legacyLibraryCreate = 'library.create';
  static const legacyLibraryUpdate = 'library.update';
  static const legacyLibraryDelete = 'library.delete';

  static const libraryReads = [
    charactersRead,
    personasRead,
    presetsRead,
    lorebooksRead,
    regexRead,
    themesRead,
  ];
  static const libraryCreates = [
    charactersCreate,
    personasCreate,
    presetsCreate,
    lorebooksCreate,
    regexCreate,
    themesCreate,
  ];
  static const libraryUpdates = [
    charactersUpdate,
    personasUpdate,
    presetsUpdate,
    lorebooksUpdate,
    regexUpdate,
    themesUpdate,
  ];
  static const libraryDeletes = [
    charactersDelete,
    personasDelete,
    presetsDelete,
    lorebooksDelete,
    regexDelete,
    themesDelete,
  ];

  /// Kind by kind, each read, create, update, delete: the order they are
  /// listed in.
  static const library = [
    charactersRead,
    charactersCreate,
    charactersUpdate,
    charactersDelete,
    personasRead,
    personasCreate,
    personasUpdate,
    personasDelete,
    presetsRead,
    presetsCreate,
    presetsUpdate,
    presetsDelete,
    lorebooksRead,
    lorebooksCreate,
    lorebooksUpdate,
    lorebooksDelete,
    regexRead,
    regexCreate,
    regexUpdate,
    regexDelete,
    themesRead,
    themesCreate,
    themesUpdate,
    themesDelete,
  ];
  static const chats = [chatsRead, chatsCreate, chatsUpdate, chatsDelete];

  static const all = {
    composer,
    messages,
    variables,
    variablesShared,
    files,
    generate,
    images,
    network,
    ...library,
    ...chats,
  };

  /// Permissions that ask the user each time unless set to always allow.
  /// [names] with the permissions that were split up replaced by their
  /// parts.
  static Set<String> expand(Iterable<String> names) => {
    for (final p in names)
      if (p == legacyLibrary) ...[
        ...library,
        ...chats,
      ] else if (p == legacyLibraryRead)
        ...libraryReads
      else if (p == legacyLibraryCreate)
        ...libraryCreates
      else if (p == legacyLibraryUpdate)
        ...libraryUpdates
      else if (p == legacyLibraryDelete)
        ...libraryDeletes
      else
        p,
  };

  static const asking = {
    images,
    ...libraryCreates,
    ...libraryUpdates,
    ...libraryDeletes,
    chatsCreate,
    chatsUpdate,
    chatsDelete,
  };
}

/// The broad kind of a permission, for sorting and filtering.
enum PluginPermissionCategory {
  general,
  network,
  variables,
  library,
  chats;

  static PluginPermissionCategory of(String permission) {
    if (permission == PluginPermission.network) return network;
    if (permission == PluginPermission.variables ||
        permission == PluginPermission.variablesShared) {
      return variables;
    }
    if (PluginPermission.library.contains(permission)) return library;
    if (PluginPermission.chats.contains(permission)) return chats;
    return general;
  }
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
    this.hostDescriptions = const {},
    this.composerActions = const [],
    this.toolsActions = const [],
    this.messageActions = const [],
    this.panels = const [],
    this.fileHandlers = const [],
    this.settings = const [],
    this.settingsTabs = const [],
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
  /// the `network` permission and the listed-hosts mode, the plugin may reach
  /// these unless the user switches one off.
  final List<String> hosts;

  /// What the plugin uses a host in [hosts] for, by host.
  final Map<String, PluginText> hostDescriptions;
  final List<PluginAction> composerActions;
  final List<PluginAction> toolsActions;
  final List<PluginAction> messageActions;
  final List<PluginPanel> panels;
  final List<PluginFileHandler> fileHandlers;
  final List<PluginSettingField> settings;

  /// The plugin's own tabs, at most [PluginSettingsTab.max]; empty puts every
  /// field on one Settings tab.
  final List<PluginSettingsTab> settingsTabs;

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

/// Whether [next] comes from the author of the installed [previous]; an
/// update from someone else is not trusted with the old plugin's grants and
/// data. Authors are only what manifests say, so this guards against
/// mistakes and lazy impostors; the confirmation before an update is what
/// the user decides on.
bool isSamePluginAuthor(PluginManifest? previous, PluginManifest next) {
  if (previous == null) return false;
  String norm(String? a) => (a ?? '').trim().toLowerCase();
  return norm(previous.author) == norm(next.author);
}
