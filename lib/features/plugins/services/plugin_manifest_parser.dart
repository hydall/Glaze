import '../models/plugin_manifest.dart';
import '../models/plugin_settings_schema.dart';

/// Highest `plugin.json` format this build understands.
const int kPluginManifestFormat = 1;

final RegExp _pluginIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,127}$');
final RegExp _semverPattern = RegExp(
  r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
  r'(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z.-]+)?$',
);
final RegExp _localeTagPattern = RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$');

/// Package-relative path rule shared by the manifest and the zip reader:
/// forward slashes only, no absolute paths, no schemes, no `..` segments.
bool isSafePluginPath(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains('\\')) {
    return false;
  }
  if (path.contains(':')) return false;
  return !path.split('/').any((s) => s.isEmpty || s == '.' || s == '..');
}

/// Turns a decoded `plugin.json` into a [PluginManifest].
PluginManifest parsePluginManifest(Object? json) {
  if (json is! Map) {
    throw const PluginManifestException('plugin.json must be an object');
  }
  final raw = Map<String, dynamic>.from(json);
  final format = raw['format'];
  if (format is! int || format < 1) {
    throw PluginManifestException('plugin.json format is invalid: $format');
  }
  if (format > kPluginManifestFormat) {
    throw PluginManifestException('Plugin format $format needs a newer Glaze');
  }

  final id = raw['id'];
  if (id is! String || !_pluginIdPattern.hasMatch(id.toLowerCase())) {
    throw PluginManifestException('Plugin id is invalid: $id');
  }
  final name = PluginText.tryParse(raw['name']);
  if (name == null) {
    throw const PluginManifestException('plugin.json is missing: name');
  }
  final version = raw['version'];
  if (version is! String || version.trim().isEmpty) {
    throw const PluginManifestException('plugin.json is missing: version');
  }
  // Converted packages keep their original version string.
  final compat = raw['compat'] is String ? raw['compat'] as String : null;
  if (compat == null && !_semverPattern.hasMatch(version)) {
    throw PluginManifestException('version must be SemVer: $version');
  }

  String? path(String field, Object? value) {
    if (value == null) return null;
    if (value is! String || !isSafePluginPath(value)) {
      throw PluginManifestException('$field is not a safe package path');
    }
    return value;
  }

  String? defaultLocale;
  final localeFiles = <String, String>{};
  final locales = raw['locales'];
  if (locales is Map) {
    final def = locales['default'];
    if (def is! String || !_localeTagPattern.hasMatch(def)) {
      throw PluginManifestException('locales.default is invalid: $def');
    }
    defaultLocale = def;
    final files = locales['files'];
    if (files is Map) {
      for (final e in files.entries) {
        final tag = e.key;
        if (tag is! String || !_localeTagPattern.hasMatch(tag)) {
          throw PluginManifestException('Locale tag is invalid: $tag');
        }
        localeFiles[tag] = path('locales.files', e.value)!;
      }
    }
  } else if (locales != null) {
    throw const PluginManifestException('locales must be an object');
  }

  final permissions = PluginPermission.expand([
    for (final p
        in (raw['permissions'] is List ? raw['permissions'] as List : const []))
      if (p is String) p,
  ]).toList();

  final hosts = <String>[];
  final rawHosts = raw['hosts'];
  if (rawHosts != null && rawHosts is! List) {
    throw const PluginManifestException('hosts must be an array');
  }
  for (final h in (rawHosts as List?) ?? const []) {
    final host = h is String ? normalizePluginHost(h) : null;
    if (host == null) {
      throw PluginManifestException('hosts has an invalid host: $h');
    }
    if (!hosts.contains(host)) hosts.add(host);
  }

  final contributes = raw['contributes'] is Map
      ? Map<String, dynamic>.from(raw['contributes'] as Map)
      : const <String, dynamic>{};

  List<PluginAction> actions(String field, {bool message = false}) {
    final list = contributes[field];
    if (list == null) return const [];
    if (list is! List) {
      throw PluginManifestException('contributes.$field must be an array');
    }
    final seen = <String>{};
    return [
      for (final (i, a) in list.indexed)
        () {
          if (a is! Map || a['id'] is! String || (a['id'] as String).isEmpty) {
            throw PluginManifestException('contributes.$field[$i] needs an id');
          }
          final actionId = a['id'] as String;
          if (!seen.add(actionId)) {
            throw PluginManifestException(
              'contributes.$field has a duplicate id: $actionId',
            );
          }
          final label = PluginText.tryParse(a['label']);
          if (label == null) {
            throw PluginManifestException(
              'contributes.$field[$i] needs a label',
            );
          }
          final role = a['role'];
          return PluginAction(
            id: actionId,
            label: label,
            icon: path('contributes.$field[$i].icon', a['icon']),
            role: message && (role == 'user' || role == 'any')
                ? role as String
                : 'character',
          );
        }(),
    ];
  }

  final composerActions = actions('composerActions');
  final toolsActions = actions('toolsActions');
  final messageActions = actions('messageActions', message: true);
  final main = path('main', raw['main']);
  if ((composerActions.isNotEmpty ||
          toolsActions.isNotEmpty ||
          messageActions.isNotEmpty) &&
      main == null) {
    throw const PluginManifestException(
      'Plugins with actions need a main script',
    );
  }

  final panels = <PluginPanel>[];
  final rawPanels = contributes['panels'];
  if (rawPanels is List) {
    for (final (i, f) in rawPanels.indexed) {
      if (f is! Map || f['id'] is! String) {
        throw PluginManifestException('panels[$i] needs an id');
      }
      final placement = switch (f['placement']) {
        'chat' => PluginPanelPlacement.chat,
        'message' => PluginPanelPlacement.message,
        _ => throw PluginManifestException(
          'panels[$i].placement must be chat or message',
        ),
      };
      final slot = f['slot'] ?? 'end';
      final role = f['role'];
      final position = f['position'];
      if (!const {'start', 'end'}.contains(slot) ||
          (role != null && !const {'user', 'character'}.contains(role)) ||
          (position != null && !const {'first', 'last'}.contains(position))) {
        throw PluginManifestException('panels[$i] has an invalid placement');
      }
      panels.add(
        PluginPanel(
          id: f['id'] as String,
          src: path('panels[$i].src', f['src'] ?? '') ?? '',
          placement: placement,
          slot: slot as String,
          role: role as String?,
          position: position as String?,
        ),
      );
    }
  }

  final fileHandlers = <PluginFileHandler>[];
  final rawHandlers = contributes['fileHandlers'];
  if (rawHandlers is List) {
    for (final (i, h) in rawHandlers.indexed) {
      if (h is! Map || h['id'] is! String) {
        throw PluginManifestException('fileHandlers[$i] needs an id');
      }
      List<String> strings(Object? v) => [
        for (final x in (v is List ? v : const []))
          if (x is String) x.toLowerCase(),
      ];
      final extensions = strings(h['extensions']);
      final mimeTypes = strings(h['mimeTypes']);
      if (extensions.isEmpty && mimeTypes.isEmpty) {
        throw PluginManifestException(
          'fileHandlers[$i] needs extensions or mimeTypes',
        );
      }
      final scripts = [
        for (final s
            in (h['scripts'] is List ? h['scripts'] as List : const []))
          path('fileHandlers[$i].scripts', s)!,
      ];
      fileHandlers.add(
        PluginFileHandler(
          id: h['id'] as String,
          extensions: extensions,
          mimeTypes: mimeTypes,
          scripts: scripts,
          icon: path('fileHandlers[$i].icon', h['icon']),
        ),
      );
    }
  }

  final settings = <PluginSettingField>[];
  final rawSettings = contributes['settings'];
  if (rawSettings is List) {
    for (final (i, s) in rawSettings.indexed) {
      settings.add(PluginSettingField.parse(s, i));
    }
  }

  final author = raw['author'];
  final minVersion = raw['minGlazeVersion'];
  return PluginManifest(
    format: format,
    id: id.toLowerCase(),
    name: name,
    version: version,
    raw: raw,
    main: main,
    author: author is String && author.trim().isNotEmpty ? author : null,
    description: PluginText.tryParse(raw['description']),
    releaseNotes: PluginText.tryParse(raw['releaseNotes']),
    defaultLocale: defaultLocale,
    localeFiles: localeFiles,
    icon: path('icon', raw['icon']),
    minGlazeVersion: minVersion is String ? minVersion : null,
    compat: compat,
    permissions: permissions,
    hosts: hosts,
    composerActions: composerActions,
    toolsActions: toolsActions,
    messageActions: messageActions,
    panels: panels,
    fileHandlers: fileHandlers,
    settings: settings,
  );
}
