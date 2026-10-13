import '../../models/plugin_manifest.dart';
import '../../services/plugin_manifest_parser.dart';

/// Compatibility with Tavo plugin packages (`.tpg`, `manifest.json`).
///
/// Tavo packages are converted to a Glaze `plugin.json` on import; the
/// runtime then loads the `tavo.*` script API on top of `glaze.*` for them.
const String kTavoCompat = 'tavo';
const String kTavoManifestFile = 'manifest.json';

final RegExp _semver = RegExp(
  r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
  r'(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z.-]+)?$',
);

const _permissionMap = {
  'input': PluginPermission.composer,
  'message': PluginPermission.messages,
  'variable': PluginPermission.variables,
  'file': PluginPermission.files,
  'generate': PluginPermission.generate,
  'network': PluginPermission.network,
  'tts': 'tts',
};

/// Tavo lets every plugin read the library and other chats and asks the
/// user before writes; Glaze has permissions for those. Its manifest does
/// not say which a plugin uses, so they are read off the plugin's scripts:
/// `tavo.<namespace>.<method>` (or the namespace reached some other way and
/// the method called on it), and the notifications it listens to.
Set<String> inferTavoPermissions(Iterable<String> sources) {
  final found = <String>{};
  final call = RegExp(
    r'\b(character|persona|preset|lorebook|regex|theme|chat|image)\s*\.\s*'
    r'(assets\s*\.\s*)?([A-Za-z]+)\b',
  );
  // Tavo sends chat and message notifications to every plugin; in Glaze
  // they come with `messages`.
  final events = RegExp(r'''['"`](chat|message):[a-z]+['"`]''');
  for (final source in sources) {
    if (events.hasMatch(source)) found.add(PluginPermission.messages);
    for (final m in call.allMatches(source)) {
      final ns = m.group(1)!;
      final asset = m.group(2) != null;
      final method = m.group(3)!;
      if (ns == 'image') {
        if (method == 'generate') found.add(PluginPermission.images);
        continue;
      }
      if (ns == 'chat') {
        final p = switch (method) {
          'get' || 'find' || 'open' || 'export' => PluginPermission.chatsRead,
          'create' || 'import' => PluginPermission.chatsCreate,
          'copy' => PluginPermission.chatsCreate,
          'update' => PluginPermission.chatsUpdate,
          'delete' => PluginPermission.chatsDelete,
          _ => null,
        };
        if (p != null) found.add(p);
        if (method == 'copy') found.add(PluginPermission.chatsRead);
        continue;
      }
      final action = asset
          ? switch (method) {
              'list' || 'export' => 'read',
              'import' || 'rename' || 'delete' => 'update',
              _ => null,
            }
          : switch (method) {
              'all' || 'get' || 'find' || 'current' || 'export' => 'read',
              'create' || 'import' => 'create',
              'update' => 'update',
              'delete' => 'delete',
              _ => null,
            };
      if (action != null) found.add('library.$action.${_kinds[ns]}');
    }
  }
  return found;
}

/// Tavo namespace → the kind in Glaze's `library.<action>.<kind>`.
const _kinds = {
  'character': 'characters',
  'persona': 'personas',
  'preset': 'presets',
  'lorebook': 'lorebooks',
  'regex': 'regex',
  'theme': 'themes',
};

const _settingTypes = {
  'switch': 'toggle',
  'select': 'select',
  'slider': 'slider',
  'text': 'text',
  'textarea': 'textarea',
  'info': 'note',
  'divider': 'divider',
  'break': 'group',
};

/// Converts a Tavo `manifest.json` (spec v1 or v2) into a Glaze `plugin.json`
/// map, checking the rules Tavo's installer enforces.
Map<String, dynamic> convertTavoManifest(Object? json) {
  if (json is! Map) {
    throw const PluginManifestException('manifest.json must be an object');
  }
  final tavo = Map<String, dynamic>.from(json);
  final spec = tavo['specVersion'] ?? 1;
  if (spec is! int || spec < 1 || spec > 2) {
    throw PluginManifestException('Unsupported Tavo specVersion: $spec');
  }
  final v2 = spec == 2;
  final version = tavo['version'];
  if (v2 && (version is! String || !_semver.hasMatch(version))) {
    throw PluginManifestException('version must be SemVer: $version');
  }
  if (v2) {
    for (final field in ['author', 'description', 'localization']) {
      if (tavo[field] == null) {
        throw PluginManifestException('manifest.json is missing: $field');
      }
    }
  }

  final scripts = tavo['scripts'];
  final contributes = tavo['contributes'] is Map
      ? Map<String, dynamic>.from(tavo['contributes'] as Map)
      : const <String, dynamic>{};

  final permissions = <String>{
    for (final p
        in (tavo['permissions'] is List
            ? tavo['permissions'] as List
            : const []))
      ?_permissionMap[p],
  };

  final localization = tavo['localization'];
  final settings = contributes['settings'];
  final out = <String, dynamic>{
    'format': kPluginManifestFormat,
    'compat': kTavoCompat,
    'id': tavo['id'],
    'name': _text(tavo['name']),
    'version': version,
    'author': ?tavo['author'],
    if (tavo['description'] != null) 'description': _text(tavo['description']),
    if (tavo['releaseNotes'] != null)
      'releaseNotes': _text(tavo['releaseNotes']),
    if (localization is Map)
      'locales': {
        'default': localization['defaultLocale'],
        if (localization['resources'] != null)
          'files': localization['resources'],
      },
    if (tavo['cover'] != null) 'icon': tavo['cover'],
    'main': tavo['entry'] ?? (scripts is Map ? scripts['actions'] : null),
    'permissions': permissions.toList(),
    'contributes': {
      'composerActions': _actions(contributes['inputActions']),
      'toolsActions': _actions(contributes['sidebar']),
      'messageActions': _actions(contributes['lastMessageActions']),
      'panels': [
        for (final f
            in (contributes['htmlFragments'] is List
                ? contributes['htmlFragments'] as List
                : const []))
          if (f is Map) _panel(f),
      ],
      'fileHandlers': [
        for (final h
            in (contributes['fileProcessors'] is List
                ? contributes['fileProcessors'] as List
                : const []))
          if (h is Map)
            {
              'id': h['id'],
              'extensions': h['extensions'] ?? const <Object>[],
              'mimeTypes': h['mimeTypes'] ?? const <Object>[],
              'scripts': switch (h['entry']) {
                final String s => <Object>[s],
                final List<Object?> l => l,
                _ => const <Object>[],
              },
              if (h['icon'] != null) 'icon': h['icon'],
            },
      ],
      'settings': [
        if (settings is Map && settings['schema'] is List)
          for (final s in settings['schema'] as List)
            if (s is Map) _setting(s),
      ],
    },
  };
  // Validate the result the same way a native plugin.json is.
  parsePluginManifest(out);
  return out;
}

/// `{ "$t": "key" }` → `{ "t": "key" }`; everything else unchanged.
Object? _text(Object? v) {
  if (v is Map && v.length == 1 && v[r'$t'] is String) return {'t': v[r'$t']};
  return v;
}

List<Map<String, dynamic>> _actions(Object? list) => [
  for (final a in (list is List ? list : const []))
    if (a is Map) {...Map<String, dynamic>.from(a), 'label': _text(a['label'])},
];

Map<String, dynamic> _setting(Map<dynamic, dynamic> s) {
  final out = <String, dynamic>{};
  for (final e in s.entries) {
    final key = e.key as String;
    out[key] = switch (key) {
      'type' => _settingTypes[e.value] ?? e.value,
      'options' => [
        for (final o in (e.value is List ? e.value as List : const []))
          o is Map
              ? {...Map<String, dynamic>.from(o), 'label': _text(o['label'])}
              : o,
      ],
      _ => _text(e.value),
    };
  }
  return out;
}

Map<String, dynamic> _panel(Map<dynamic, dynamic> f) {
  final mount = f['mount'];
  final uri = mount is String ? Uri.tryParse(mount) : null;
  final segments = uri?.pathSegments.where((s) => s.isNotEmpty).toList() ?? [];
  if (uri == null || segments.isEmpty) {
    throw PluginManifestException('htmlFragments mount is invalid: $mount');
  }
  final message = segments.first == 'messages';
  if (!message && segments.first != 'chat') {
    throw PluginManifestException('htmlFragments mount is invalid: $mount');
  }
  final slot = segments.length > 1 ? segments.last : 'end';
  return {
    'id': f['id'],
    'src': f['src'],
    'placement': message ? 'message' : 'chat',
    'slot': slot == 'start' ? 'start' : 'end',
    if (message && uri.queryParameters['role'] != null)
      'role': uri.queryParameters['role'],
    if (message && uri.queryParameters['position'] != null)
      'position': uri.queryParameters['position'],
  };
}
