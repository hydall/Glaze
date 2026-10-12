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
  });

  final PluginManifest manifest;
  final String directory;
  final bool enabled;
  final int installedAt;

  /// User overrides of settings values, by schema key.
  final Map<String, Object?> config;

  /// Locale tag → flat catalog.
  final Map<String, Map<String, String>> catalogs;

  String get id => manifest.id;

  InstalledPlugin copyWith({bool? enabled, Map<String, Object?>? config}) =>
      InstalledPlugin(
        manifest: manifest,
        directory: directory,
        enabled: enabled ?? this.enabled,
        installedAt: installedAt,
        config: config ?? this.config,
        catalogs: catalogs,
      );

  PluginLocalizer localizer(String requestedLocale) => PluginLocalizer(
    catalogs: catalogs,
    defaultLocale: manifest.defaultLocale,
    requestedLocale: requestedLocale,
  );

  /// Saved value, else schema default, for every keyed field — what
  /// `tavo.plugin.config.all()` returns.
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
  };
}
