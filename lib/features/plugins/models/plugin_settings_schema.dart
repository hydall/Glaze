import 'plugin_manifest.dart';

/// Field types of `contributes.settings.schema`.
enum PluginSettingType {
  toggle,
  select,
  slider,
  text,
  textarea,
  info,
  divider,
  sectionBreak,
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

  /// `info` only: `info` or `warning`.
  final String? icon;

  bool get storesValue => key != null;

  static const _types = {
    'switch': PluginSettingType.toggle,
    'select': PluginSettingType.select,
    'slider': PluginSettingType.slider,
    'text': PluginSettingType.text,
    'textarea': PluginSettingType.textarea,
    'info': PluginSettingType.info,
    'divider': PluginSettingType.divider,
    'break': PluginSettingType.sectionBreak,
  };

  static PluginSettingField parse(Object? raw, int index) {
    if (raw is! Map) {
      throw PluginManifestException(
        'settings.schema[$index] must be an object',
      );
    }
    final type = _types[raw['type']];
    if (type == null) {
      throw PluginManifestException(
        'settings.schema[$index] has an unsupported type: ${raw['type']}',
      );
    }
    String requireKey() {
      final key = raw['key'];
      if (key is! String || key.isEmpty) {
        throw PluginManifestException('settings.schema[$index] needs a key');
      }
      return key;
    }

    PluginText requireText(String field) {
      final text = PluginText.tryParse(raw[field]);
      if (text == null) {
        throw PluginManifestException('settings.schema[$index] needs a $field');
      }
      return text;
    }

    double? number(String field) {
      final v = raw[field];
      return v is num ? v.toDouble() : null;
    }

    switch (type) {
      case PluginSettingType.info:
        return PluginSettingField(
          type: type,
          label: requireText('text'),
          icon: raw['icon'] == 'warning' ? 'warning' : 'info',
        );
      case PluginSettingType.divider:
      case PluginSettingType.sectionBreak:
        return PluginSettingField(type: type);
      case PluginSettingType.select:
        final rawOptions = raw['options'];
        if (rawOptions is! List || rawOptions.isEmpty) {
          throw PluginManifestException(
            'settings.schema[$index] select needs options',
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
              'settings.schema[$index] has an invalid option',
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
            'settings.schema[$index] slider needs min < max',
          );
        }
        if (step != null && step <= 0) {
          throw PluginManifestException(
            'settings.schema[$index] slider step must be positive',
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
