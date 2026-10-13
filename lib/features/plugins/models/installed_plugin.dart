import '../services/plugin_localizer.dart';
import 'plugin_manifest.dart';
import 'plugin_settings_schema.dart';

/// A plugin unpacked under `<data>/plugins/<id>/` plus its saved state.
class InstalledPlugin {
  const InstalledPlugin({
    required this.manifest,
    required this.directory,
    required this.enabled,
    required this.installedAt,
    this.config = const {},
    this.catalogs = const {},
    this.grants = const {},
    this.revoked = const {},
    this.networkHosts,
    this.localNetwork = false,
  });

  final PluginManifest manifest;
  final String directory;
  final bool enabled;
  final int installedAt;

  /// User overrides of settings values, by schema key.
  final Map<String, Object?> config;

  /// Locale tag → flat catalog.
  final Map<String, Map<String, String>> catalogs;

  /// Asking permissions the user allowed for good (`PluginPermission` names).
  final Set<String> grants;

  /// Manifest permissions the user switched off.
  final Set<String> revoked;

  /// With `network` allowed: the only hosts the plugin may reach, or null
  /// for any host.
  final Set<String>? networkHosts;

  /// With `network` allowed: whether the plugin may also reach devices on
  /// the user's own network (loopback, private and link-local addresses)
  /// and use unencrypted http/ws.
  final bool localNetwork;

  /// Whether the plugin may reach [host] at all.
  bool allowsHost(String host) {
    if (!allows(PluginPermission.network)) return false;
    final list = networkHosts;
    return list == null || pluginHostAllowed(list, host);
  }

  String get id => manifest.id;

  /// Whether the manifest asks for [permission] and the user has not taken
  /// it away.
  bool allows(String permission) =>
      manifest.hasPermission(permission) && !revoked.contains(permission);

  InstalledPlugin copyWith({
    bool? enabled,
    Map<String, Object?>? config,
    Set<String>? grants,
    Set<String>? revoked,
    Set<String>? Function()? networkHosts,
    bool? localNetwork,
  }) => InstalledPlugin(
    manifest: manifest,
    directory: directory,
    enabled: enabled ?? this.enabled,
    installedAt: installedAt,
    config: config ?? this.config,
    catalogs: catalogs,
    grants: grants ?? this.grants,
    revoked: revoked ?? this.revoked,
    networkHosts: networkHosts == null ? this.networkHosts : networkHosts(),
    localNetwork: localNetwork ?? this.localNetwork,
  );

  PluginLocalizer localizer(String requestedLocale) => PluginLocalizer(
    catalogs: catalogs,
    defaultLocale: manifest.defaultLocale,
    requestedLocale: requestedLocale,
  );

  /// Saved value, else schema default, for every keyed field — what
  /// `glaze.plugin.settings.all()` returns.
  Map<String, Object?> effectiveConfig(PluginLocalizer localizer) {
    final out = <String, Object?>{};
    for (final field in manifest.settings) {
      final key = field.key;
      if (key == null) continue;
      out[key] = config.containsKey(key)
          ? config[key]
          : defaultFor(field, localizer);
    }
    return out;
  }

  static Object? defaultFor(
    PluginSettingField field,
    PluginLocalizer localizer,
  ) {
    final d = field.defaultValue;
    return d is PluginText ? localizer.resolve(d) : d;
  }

  Map<String, Object?> toRecord() => {
    'id': id,
    'enabled': enabled,
    'installedAt': installedAt,
    'config': config,
    'grants': grants.toList(),
    'revoked': revoked.toList(),
    'networkHosts': networkHosts?.toList(),
    'localNetwork': localNetwork,
  };
}
