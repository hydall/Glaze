import 'plugin_manifest.dart';

/// Field types of `contributes.settings`.
enum PluginSettingType {
  toggle,
  select,
  slider,
  text,
  textarea,
  note,
  divider,
  group,

  /// An API connection (and model) one of the plugin's features generates
  /// text on: `glaze.generate(prompt, {preset: key})`.
  apiPreset,

  /// An image service and image style one of the plugin's features draws
  /// with: `glaze.images.generate(prompt, {preset: key})`.
  imagePreset,
}

/// [PluginPresetValue.style] that overrides the image settings' active style
/// with none at all, rather than following it.
const String kPluginNoImageStyle = '@none';

/// What an [PluginSettingType.apiPreset] / [PluginSettingType.imagePreset]
/// field stores. Text: the API connection ([api], empty follows the chat's)
/// and a model override. Images: the image service ([provider]) and style
/// ([style]); empty follows the image settings, [kPluginNoImageStyle] forces
/// no style.
class PluginPresetValue {
  const PluginPresetValue({
    this.api = '',
    this.model = '',
    this.provider = '',
    this.style = '',
  });

  factory PluginPresetValue.parse(Object? raw) {
    if (raw is! Map) return const PluginPresetValue();
    String read(String key) => raw[key] is String ? raw[key] as String : '';
    return PluginPresetValue(
      api: read('api'),
      model: read('model'),
      provider: read('provider'),
      style: read('style'),
    );
  }

  /// Connection id (`apiPreset`).
  final String api;

  /// Model on [api] (`apiPreset`).
  final String model;

  /// [ImageGenApiType] name the `imagePreset` draws with; empty follows the
  /// image generation settings.
  final String provider;

  /// Image style id (`imagePreset`), or [kPluginNoImageStyle].
  final String style;

  PluginPresetValue copyWith({
    String? api,
    String? model,
    String? provider,
    String? style,
  }) => PluginPresetValue(
    api: api ?? this.api,
    model: model ?? this.model,
    provider: provider ?? this.provider,
    style: style ?? this.style,
  );

  Map<String, Object?> toJson() => {
    if (api.isNotEmpty) 'api': api,
    if (model.isNotEmpty) 'model': model,
    if (provider.isNotEmpty) 'provider': provider,
    if (style.isNotEmpty) 'style': style,
  };
}

/// One of the plugin's own tabs on its screen (`contributes.settingsTabs`),
/// holding the settings fields that name it.
class PluginSettingsTab {
  const PluginSettingsTab({required this.id, required this.label, this.icon});

  /// How many tabs a plugin may add.
  static const max = 10;

  final String id;
  final PluginText label;

  /// A package image.
  final String? icon;
}

class PluginSelectOption {
  const PluginSelectOption({required this.value, required this.label});
  final String value;
  final PluginText label;
}

/// One element of the plugin settings form, rendered in manifest order.
class PluginSettingField {
  const PluginSettingField({
    required this.type,
    this.key,
    this.label,
    this.description,
    this.defaultValue,
    this.options = const [],
    this.min,
    this.max,
    this.step,
    this.icon,
    this.tab,
  });

  final PluginSettingType type;
  final String? key;

  /// Field label, or the `text` of an `info` element.
  final PluginText? label;
  final PluginText? description;

  /// Raw schema default. For text fields it may be a [PluginText].
  final Object? defaultValue;
  final List<PluginSelectOption> options;
  final double? min;
  final double? max;
  final double? step;

  /// `note` only: `info` or `warning`.
  final String? icon;

  /// The id of the [PluginSettingsTab] the field is on; null puts it on the
  /// first one.
  final String? tab;

  bool get storesValue => key != null;

  static const _types = {
    'toggle': PluginSettingType.toggle,
    'select': PluginSettingType.select,
    'slider': PluginSettingType.slider,
    'text': PluginSettingType.text,
    'textarea': PluginSettingType.textarea,
    'note': PluginSettingType.note,
    'divider': PluginSettingType.divider,
    'group': PluginSettingType.group,
    'apiPreset': PluginSettingType.apiPreset,
    'imagePreset': PluginSettingType.imagePreset,
  };

  static PluginSettingField parse(Object? raw, int index) {
    if (raw is! Map) {
      throw PluginManifestException('settings[$index] must be an object');
    }
    final tab = raw['tab'];
    if (tab != null && (tab is! String || tab.isEmpty)) {
      throw PluginManifestException('settings[$index] has an invalid tab');
    }
    return _parse(raw, index)._onTab(tab as String?);
  }

  PluginSettingField _onTab(String? tab) => tab == null
      ? this
      : PluginSettingField(
          type: type,
          key: key,
          label: label,
          description: description,
          defaultValue: defaultValue,
          options: options,
          min: min,
          max: max,
          step: step,
          icon: icon,
          tab: tab,
        );

  static PluginSettingField _parse(Map<dynamic, dynamic> raw, int index) {
    final type = _types[raw['type']];
    if (type == null) {
      throw PluginManifestException(
        'settings[$index] has an unsupported type: ${raw['type']}',
      );
    }
    String requireKey() {
      final key = raw['key'];
      if (key is! String || key.isEmpty) {
        throw PluginManifestException('settings[$index] needs a key');
      }
      return key;
    }

    PluginText requireText(String field) {
      final text = PluginText.tryParse(raw[field]);
      if (text == null) {
        throw PluginManifestException('settings[$index] needs a $field');
      }
      return text;
    }

    double? number(String field) {
      final v = raw[field];
      return v is num ? v.toDouble() : null;
    }

    switch (type) {
      case PluginSettingType.note:
        return PluginSettingField(
          type: type,
          label: requireText('text'),
          icon: raw['icon'] == 'warning' ? 'warning' : 'info',
        );
      case PluginSettingType.divider:
      case PluginSettingType.group:
        return PluginSettingField(type: type);
      case PluginSettingType.select:
        final rawOptions = raw['options'];
        if (rawOptions is! List || rawOptions.isEmpty) {
          throw PluginManifestException(
            'settings[$index] select needs options',
          );
        }
        final options = <PluginSelectOption>[];
        for (final o in rawOptions) {
          if (o is String) {
            options.add(
              PluginSelectOption(value: o, label: PluginText.literal(o)),
            );
          } else if (o is Map && o['value'] is String) {
            options.add(
              PluginSelectOption(
                value: o['value'] as String,
                label:
                    PluginText.tryParse(o['label']) ??
                    PluginText.literal(o['value'] as String),
              ),
            );
          } else {
            throw PluginManifestException(
              'settings[$index] has an invalid option',
            );
          }
        }
        return PluginSettingField(
          type: type,
          key: requireKey(),
          label: requireText('label'),
          description: PluginText.tryParse(raw['description']),
          defaultValue: raw['default'],
          options: options,
        );
      case PluginSettingType.slider:
        final min = number('min');
        final max = number('max');
        final step = number('step');
        if (min == null || max == null || max <= min) {
          throw PluginManifestException(
            'settings[$index] slider needs min < max',
          );
        }
        if (step != null && step <= 0) {
          throw PluginManifestException(
            'settings[$index] slider step must be positive',
          );
        }
        return PluginSettingField(
          type: type,
          key: requireKey(),
          label: requireText('label'),
          description: PluginText.tryParse(raw['description']),
          defaultValue: raw['default'],
          min: min,
          max: max,
          step: step,
        );
      case PluginSettingType.apiPreset:
      case PluginSettingType.imagePreset:
        // No default: an unset preset follows the chat's connection.
        return PluginSettingField(
          type: type,
          key: requireKey(),
          label: requireText('label'),
          description: PluginText.tryParse(raw['description']),
        );
      case PluginSettingType.toggle:
      case PluginSettingType.text:
      case PluginSettingType.textarea:
        final rawDefault = raw['default'];
        return PluginSettingField(
          type: type,
          key: requireKey(),
          label: requireText('label'),
          description: PluginText.tryParse(raw['description']),
          defaultValue: type == PluginSettingType.toggle
              ? rawDefault
              : (PluginText.tryParse(rawDefault) ?? rawDefault),
        );
    }
  }
}
