import '../models/plugin_manifest.dart';
import '../models/plugin_settings_schema.dart';

/// Highest manifest `specVersion` Glaze understands (Tavo v0.93+).
const int kMaxPluginSpecVersion = 2;

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

/// Turns a decoded `manifest.json` into a [PluginManifest], enforcing the
/// Tavo rules that matter for running the plugin safely.
PluginManifest parsePluginManifest(Object? json) {
  if (json is! Map) {
    throw const PluginManifestException('manifest.json must be an object');
  }
  final raw = Map<String, dynamic>.from(json);

  final rawSpec = raw['specVersion'] ?? 1;
  if (rawSpec is! int || rawSpec < 1) {
    throw PluginManifestException(
      'manifest specVersion must be a positive integer: $rawSpec',
    );
  }
  if (rawSpec > kMaxPluginSpecVersion) {
    throw PluginManifestException(
      'Plugin specVersion $rawSpec needs a newer Glaze',
    );
  }
  final v2 = rawSpec >= 2;

  final id = raw['id'];
  if (id is! String || !_pluginIdPattern.hasMatch(id.toLowerCase())) {
    throw PluginManifestException('manifest id is invalid: $id');
  }
  final name = PluginText.tryParse(raw['name']);
  if (name == null) {
    throw const PluginManifestException(
      'manifest is missing required field: name',
    );
  }
  final version = raw['version'];
  if (version is! String || version.trim().isEmpty) {
    throw const PluginManifestException(
      'manifest is missing required field: version',
    );
  }
  if (v2 && !_semverPattern.hasMatch(version)) {
    throw PluginManifestException(
      'specVersion 2 manifest version must be valid SemVer: $version',
    );
  }

  String? path(String field, Object? value) {
    if (value == null) return null;
    if (value is! String || !isSafePluginPath(value)) {
      throw PluginManifestException('manifest $field is not a safe path');
    }
    return value;
  }

  final scripts = raw['scripts'];
  final entry =
      path('entry', raw['entry']) ??
      (scripts is Map ? path('scripts.actions', scripts['actions']) : null);

  final author = raw['author'];
  final description = PluginText.tryParse(raw['description']);
  String? defaultLocale;
  final resources = <String, String>{};
  final localization = raw['localization'];
  if (v2) {
    if (author is! String || author.trim().isEmpty) {
      throw const PluginManifestException(
        'manifest is missing required field: author',
      );
    }
    if (description == null) {
      throw const PluginManifestException(
        'manifest is missing required field: description',
      );
    }
    if (localization is! Map || localization['defaultLocale'] is! String) {
      throw const PluginManifestException(
        'manifest is missing the required localization declaration',
      );
    }
    defaultLocale = localization['defaultLocale'] as String;
    if (!_localeTagPattern.hasMatch(defaultLocale)) {
      throw PluginManifestException(
        'manifest locale tag is invalid: $defaultLocale',
      );
    }
    final res = localization['resources'];
    if (res is Map) {
      for (final e in res.entries) {
        final tag = e.key;
        if (tag is! String || !_localeTagPattern.hasMatch(tag)) {
          throw PluginManifestException('manifest locale tag is invalid: $tag');
        }
        resources[tag] = path('localization.resources', e.value)!;
      }
    } else if (res != null) {
      throw const PluginManifestException(
        'manifest localization structure is invalid',
      );
    }
  }

  final permissions = <String>[
    for (final p
        in (raw['permissions'] is List ? raw['permissions'] as List : const []))
      if (p is String) p,
  ];

  final contributes = raw['contributes'] is Map
      ? Map<String, dynamic>.from(raw['contributes'] as Map)
      : const <String, dynamic>{};

  List<PluginAction> actions(String field, {bool lastMessage = false}) {
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
            role: lastMessage && (role == 'user' || role == 'any')
                ? role as String
                : 'character',
          );
        }(),
    ];
  }

  final inputActions = actions('inputActions');
  final sidebarActions = actions('sidebar');
  final lastMessageActions = actions('lastMessageActions', lastMessage: true);
  if ((inputActions.isNotEmpty ||
          sidebarActions.isNotEmpty ||
          lastMessageActions.isNotEmpty) &&
      entry == null) {
    throw const PluginManifestException(
      'manifest is missing required field: entry',
    );
  }

  final fragments = <PluginFragment>[];
  final rawFragments = contributes['htmlFragments'];
  if (rawFragments is List) {
    for (final (i, f) in rawFragments.indexed) {
      if (f is! Map || f['id'] is! String) {
        throw PluginManifestException('htmlFragments[$i] needs an id');
      }
      final mount = f['mount'];
      if (mount is! String) {
        throw PluginManifestException('htmlFragments[$i] needs a mount');
      }
      fragments.add(
        PluginFragment(
          id: f['id'] as String,
          src: path('htmlFragments[$i].src', f['src'] ?? '') ?? '',
          mount: PluginMount.parse(mount),
        ),
      );
    }
  }

  final settings = <PluginSettingField>[];
  final rawSettings = contributes['settings'];
  if (rawSettings is Map && rawSettings['schema'] is List) {
    for (final (i, s) in (rawSettings['schema'] as List).indexed) {
      settings.add(PluginSettingField.parse(s, i));
    }
  }

  final minAppVersion = raw['minAppVersion'];
  return PluginManifest(
    specVersion: rawSpec,
    id: id.toLowerCase(),
    name: name,
    version: version,
    raw: raw,
    entry: entry,
    author: author is String ? author : null,
    description: description,
    releaseNotes: PluginText.tryParse(raw['releaseNotes']),
    defaultLocale: defaultLocale,
    localeResources: resources,
    cover: path('cover', raw['cover']),
    minAppVersion: minAppVersion is String ? minAppVersion : null,
    permissions: permissions,
    inputActions: inputActions,
    sidebarActions: sidebarActions,
    lastMessageActions: lastMessageActions,
    fragments: fragments,
    settings: settings,
    hasFileProcessors:
        contributes['fileProcessors'] is List &&
        (contributes['fileProcessors'] as List).isNotEmpty,
  );
}
