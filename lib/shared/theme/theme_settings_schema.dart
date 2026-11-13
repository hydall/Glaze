import 'dart:convert';

import 'theme_preset.dart';

/// A theme's own settings for the theme editor's Chat screen, declared in the
/// theme file under `layout.settings` (docs/THEME_LAYOUTS.md § Settings).
///
/// A declaration replaces the built-in Chat screen as a whole: its tabs, the
/// groups in each tab and the rows in each group. A row either edits one of
/// the preset's own chat fields (`"field": "userBubbleColor"`, drawn exactly
/// as the built-in screen draws it) or a value of the theme's own
/// (`"key": "accent2"` with a `type`), which reaches the theme's stylesheets
/// as a `--theme-<key>` variable and its message template as `theme.<key>`.
///
/// Parsing never throws: what cannot be used is dropped and named in
/// [ThemeSettingsSchema.errors], the rest still shows.
class ThemeSettingsSchema {
  const ThemeSettingsSchema(this.tabs, [this.errors = const []]);

  final List<ThemeSettingsTab> tabs;
  final List<String> errors;

  bool get isEmpty => tabs.isEmpty;

  /// Every row of every tab, in order.
  Iterable<ThemeSettingItem> get items sync* {
    for (final tab in tabs) {
      for (final group in tab.groups) {
        yield* group.items;
      }
    }
  }

  /// The rows that hold a value of the theme's own.
  Iterable<ThemeSettingItem> get ownItems =>
      items.where((i) => i.key != null && i.kind.holdsValue);

  /// Reads a declaration: a JSON string or the decoded object. A bare list is
  /// taken as the list of tabs. Null when there is nothing usable.
  static ThemeSettingsSchema? parse(Object? raw) {
    Object? json = raw;
    if (raw is String) {
      if (raw.trim().isEmpty) return null;
      try {
        json = jsonDecode(raw);
      } catch (_) {
        return const ThemeSettingsSchema([], ['settings: not valid JSON']);
      }
    }
    final errors = <String>[];
    final rawTabs = json is Map ? json['tabs'] : json;
    if (rawTabs is! List) return null;
    final tabs = <ThemeSettingsTab>[];
    final ids = <String>{};
    final keys = <String>{};
    for (var t = 0; t < rawTabs.length && tabs.length < _maxTabs; t++) {
      final tab = ThemeSettingsTab._parse(rawTabs[t], t, errors, keys);
      if (tab == null) continue;
      if (!ids.add(tab.id)) {
        errors.add('tab ${tab.id}: the id is used twice');
        continue;
      }
      tabs.add(tab);
    }
    if (tabs.isEmpty) return ThemeSettingsSchema(const [], errors);
    return ThemeSettingsSchema(tabs, errors);
  }

  static const _maxTabs = 8;
}

/// Text a theme shows: one string, or one per language
/// (`{"en": "Size", "ru": "Размер"}`). A string starting with `@` names one of
/// the app's own translations (`"@tab_font"`).
class ThemeText {
  const ThemeText._(this._byLocale);

  final Map<String, String> _byLocale;

  static ThemeText? parse(Object? raw) {
    if (raw is String) {
      final s = raw.trim();
      return s.isEmpty ? null : ThemeText._({'': _clip(s)});
    }
    if (raw is Map) {
      final out = <String, String>{};
      raw.forEach((k, v) {
        if (k is String && v is String && v.trim().isNotEmpty) {
          out[k.toLowerCase()] = _clip(v.trim());
        }
      });
      return out.isEmpty ? null : ThemeText._(out);
    }
    return null;
  }

  static String _clip(String s) => s.length > 200 ? s.substring(0, 200) : s;

  /// The text for [locale] (a language code), falling back to English, then
  /// to any. [translate] resolves an `@key`.
  String resolve(String locale, String Function(String key) translate) {
    final text =
        _byLocale[locale.toLowerCase()] ??
        _byLocale[''] ??
        _byLocale['en'] ??
        _byLocale.values.first;
    if (text.length > 1 && text.startsWith('@')) {
      return translate(text.substring(1));
    }
    return text;
  }
}

/// Glyphs a tab may name. A fixed set: icons are tree-shaken, so a name
/// cannot become an arbitrary code point.
const kThemeSettingTabIcons = <String>{
  'text_fields',
  'palette',
  'tune',
  'chat',
  'image',
  'brush',
  'star',
  'layers',
  'person',
  'auto_awesome',
};

class ThemeSettingsTab {
  const ThemeSettingsTab({
    required this.id,
    required this.label,
    required this.groups,
    this.icon,
  });

  final String id;
  final ThemeText label;
  final String? icon;
  final List<ThemeSettingsGroup> groups;

  static ThemeSettingsTab? _parse(
    Object? raw,
    int index,
    List<String> errors,
    Set<String> keys,
  ) {
    if (raw is! Map) {
      errors.add('tab $index: not an object');
      return null;
    }
    final id = raw['id'] is String && _isName(raw['id'] as String)
        ? raw['id'] as String
        : 'tab$index';
    final label = ThemeText.parse(raw['label']);
    if (label == null) {
      errors.add('tab $id: no label');
      return null;
    }
    final icon =
        raw['icon'] is String && kThemeSettingTabIcons.contains(raw['icon'])
        ? raw['icon'] as String
        : null;
    final groups = <ThemeSettingsGroup>[];
    final rawGroups = raw['groups'];
    if (rawGroups is List) {
      for (var g = 0; g < rawGroups.length && groups.length < 32; g++) {
        final group = ThemeSettingsGroup._parse(
          rawGroups[g],
          '$id/$g',
          errors,
          keys,
        );
        if (group != null) groups.add(group);
      }
    }
    if (groups.isEmpty) {
      errors.add('tab $id: no groups');
      return null;
    }
    return ThemeSettingsTab(id: id, label: label, icon: icon, groups: groups);
  }
}

class ThemeSettingsGroup {
  const ThemeSettingsGroup({required this.items, this.header, this.when});

  final ThemeText? header;

  /// Shown only while this condition holds (see [evaluateThemeCondition]).
  final String? when;
  final List<ThemeSettingItem> items;

  static ThemeSettingsGroup? _parse(
    Object? raw,
    String where,
    List<String> errors,
    Set<String> keys,
  ) {
    if (raw is! Map) {
      errors.add('group $where: not an object');
      return null;
    }
    final items = <ThemeSettingItem>[];
    final rawItems = raw['items'];
    if (rawItems is List) {
      for (var i = 0; i < rawItems.length && items.length < 64; i++) {
        final item = ThemeSettingItem._parse(
          rawItems[i],
          '$where/$i',
          errors,
          keys,
        );
        if (item != null) items.add(item);
      }
    }
    if (items.isEmpty) {
      errors.add('group $where: no items');
      return null;
    }
    return ThemeSettingsGroup(
      header: ThemeText.parse(raw['header']),
      when: _condition(raw['when']),
      items: items,
    );
  }
}

enum ThemeSettingKind {
  /// One of the preset's own chat fields ([kThemeSettingFields]).
  field,
  color,
  slider,
  toggle,
  select,

  /// A small heading between rows.
  subheader,

  /// A line of explanation.
  note;

  bool get holdsValue =>
      this == color || this == slider || this == toggle || this == select;
}

/// The preset fields a declaration may bind a row to — the ones the built-in
/// Chat screen edits.
const kThemeSettingFields = <String>{
  'chatLayout',
  'chatBgMode',
  'chatBgColor',
  'chatBgImage',
  'chatFontMode',
  'chatFontSize',
  'chatLetterSpacing',
  'userMessageFontWeight',
  'charMessageFontWeight',
  'userBubbleColor',
  'charBubbleColor',
  'userBubbleRadius',
  'charBubbleRadius',
  'showUserAvatar',
  'showCharAvatar',
  'showUserName',
  'showCharName',
  'hideMessageId',
  'hideGenerationTime',
  'hideTokenCount',
  'userQuoteColor',
  'charQuoteColor',
  'userTextColor',
  'charTextColor',
  'userItalicColor',
  'charItalicColor',
  'textBgOpacity',
};

class ThemeSettingOption {
  const ThemeSettingOption(this.value, this.label);
  final String value;
  final ThemeText label;
}

/// CSS units a slider's value may carry into its variable.
const _cssUnits = {'', 'px', '%', 'em', 'rem', 'deg', 's', 'ms'};

class ThemeSettingItem {
  const ThemeSettingItem({
    required this.kind,
    this.field,
    this.key,
    this.label,
    this.description,
    this.when,
    this.min = 0,
    this.max = 1,
    this.step = 0,
    this.unit = '',
    this.percent = false,
    this.options = const [],
    this.defaultValue,
  });

  final ThemeSettingKind kind;
  final String? field;
  final String? key;
  final ThemeText? label;
  final ThemeText? description;
  final String? when;

  /// Slider range; [step] 0 means continuous.
  final double min;
  final double max;
  final double step;

  /// The CSS unit the slider's value is written with.
  final String unit;

  /// Show the slider's value ×100 with a `%`.
  final bool percent;
  final List<ThemeSettingOption> options;
  final Object? defaultValue;

  int? get divisions {
    if (step <= 0) return null;
    final n = ((max - min) / step).round();
    return n > 0 && n <= 1000 ? n : null;
  }

  static ThemeSettingItem? _parse(
    Object? raw,
    String where,
    List<String> errors,
    Set<String> keys,
  ) {
    if (raw is String && kThemeSettingFields.contains(raw)) {
      return ThemeSettingItem(kind: ThemeSettingKind.field, field: raw);
    }
    if (raw is! Map) {
      errors.add('item $where: not an object');
      return null;
    }
    final label = ThemeText.parse(raw['label']);
    final description = ThemeText.parse(raw['description']);
    final when = _condition(raw['when']);

    final field = raw['field'];
    if (field != null) {
      if (field is! String || !kThemeSettingFields.contains(field)) {
        errors.add('item $where: "$field" is not a field a theme may edit');
        return null;
      }
      return ThemeSettingItem(
        kind: ThemeSettingKind.field,
        field: field,
        label: label,
        description: description,
        when: when,
      );
    }

    final type = raw['type'];
    switch (type) {
      case 'subheader':
      case 'note':
        if (label == null) {
          errors.add('item $where: a $type needs a label');
          return null;
        }
        return ThemeSettingItem(
          kind: type == 'note'
              ? ThemeSettingKind.note
              : ThemeSettingKind.subheader,
          label: label,
          when: when,
        );
    }

    final key = raw['key'];
    if (key is! String || !_isName(key)) {
      errors.add('item $where: needs a "key" of letters, digits, - and _');
      return null;
    }
    if (!keys.add(key)) {
      errors.add('item $where: the key "$key" is used twice');
      return null;
    }
    if (label == null) {
      errors.add('item $key: no label');
      return null;
    }
    final def = raw['default'];
    switch (type) {
      case 'color':
        return ThemeSettingItem(
          kind: ThemeSettingKind.color,
          key: key,
          label: label,
          description: description,
          when: when,
          defaultValue: def is String && isThemeColor(def) ? def : null,
        );
      case 'switch':
        return ThemeSettingItem(
          kind: ThemeSettingKind.toggle,
          key: key,
          label: label,
          description: description,
          when: when,
          defaultValue: def is bool ? def : false,
        );
      case 'slider':
        final min = _num(raw['min']) ?? 0;
        final max = _num(raw['max']) ?? 1;
        if (!(max > min)) {
          errors.add('item $key: "max" must be above "min"');
          return null;
        }
        final unit = raw['unit'] is String ? raw['unit'] as String : '';
        if (!_cssUnits.contains(unit)) {
          errors.add(
            'item $key: unit "$unit" is not one of ${_cssUnits.join(' ')}',
          );
          return null;
        }
        final d = _num(def);
        return ThemeSettingItem(
          kind: ThemeSettingKind.slider,
          key: key,
          label: label,
          description: description,
          when: when,
          min: min,
          max: max,
          step: (_num(raw['step']) ?? 0).clamp(0, max - min).toDouble(),
          unit: unit,
          percent: raw['percent'] == true,
          defaultValue: (d ?? min).clamp(min, max).toDouble(),
        );
      case 'select':
        final options = <ThemeSettingOption>[];
        final rawOptions = raw['options'];
        if (rawOptions is List) {
          for (final o in rawOptions) {
            if (o is! Map) continue;
            final value = o['value'];
            final optionLabel = ThemeText.parse(o['label']);
            if (value is String &&
                _isName(value) &&
                optionLabel != null &&
                options.every((x) => x.value != value)) {
              options.add(ThemeSettingOption(value, optionLabel));
            }
          }
        }
        if (options.isEmpty) {
          errors.add('item $key: a select needs options');
          return null;
        }
        return ThemeSettingItem(
          kind: ThemeSettingKind.select,
          key: key,
          label: label,
          description: description,
          when: when,
          options: options,
          defaultValue: options.any((o) => o.value == def)
              ? def
              : options.first.value,
        );
    }
    errors.add('item $key: unknown type "$type"');
    return null;
  }
}

bool _isName(String s) => RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,39}$').hasMatch(s);

bool isThemeColor(String s) =>
    RegExp(r'^#([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(s);

double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

String? _condition(Object? raw) =>
    raw is String && raw.trim().isNotEmpty && raw.length <= 300
    ? raw.trim()
    : null;

/// The values of a theme's own settings, as the chat page takes them: CSS
/// variables, class flags and the raw values for templates.
class ThemeSettingValues {
  const ThemeSettingValues({
    required this.vars,
    required this.flags,
    required this.values,
  });

  /// key → CSS value; the page sets `--theme-<key>`.
  final Map<String, String> vars;

  /// The page sets a `theme-<flag>` class for each.
  final List<String> flags;

  /// key → value (bool, number or string), for `theme.<key>` in a template.
  final Map<String, Object> values;

  bool get isEmpty => vars.isEmpty && flags.isEmpty && values.isEmpty;

  Map<String, Object> toJson() => {
    'vars': vars,
    'flags': flags,
    'values': values,
  };
}

/// The value a setting of the theme's own holds: the stored one when it
/// still fits the declaration, otherwise the declared default.
Object? themeSettingValue(ThemeSettingItem item, Map<String, dynamic> stored) {
  final v = stored[item.key];
  switch (item.kind) {
    case ThemeSettingKind.color:
      return v is String && isThemeColor(v) ? v : item.defaultValue;
    case ThemeSettingKind.toggle:
      return v is bool ? v : item.defaultValue;
    case ThemeSettingKind.slider:
      return v is num && v.isFinite
          ? v.toDouble().clamp(item.min, item.max)
          : item.defaultValue;
    case ThemeSettingKind.select:
      return v is String && item.options.any((o) => o.value == v)
          ? v
          : item.defaultValue;
    default:
      return null;
  }
}

String _cssNumber(double v) {
  final rounded = double.parse(v.toStringAsFixed(4));
  return rounded == rounded.roundToDouble()
      ? rounded.toInt().toString()
      : rounded.toString();
}

/// Builds what the page gets for [schema]'s own settings.
ThemeSettingValues themeSettingValues(
  ThemeSettingsSchema? schema,
  Map<String, dynamic> stored,
) {
  final vars = <String, String>{};
  final flags = <String>[];
  final values = <String, Object>{};
  if (schema == null) {
    return ThemeSettingValues(vars: vars, flags: flags, values: values);
  }
  for (final item in schema.ownItems) {
    final key = item.key!;
    final value = themeSettingValue(item, stored);
    if (value == null) continue;
    values[key] = value;
    switch (item.kind) {
      case ThemeSettingKind.color:
        vars[key] = value as String;
      case ThemeSettingKind.toggle:
        vars[key] = value == true ? '1' : '0';
        if (value == true) flags.add(key);
      case ThemeSettingKind.slider:
        vars[key] = '${_cssNumber(value as double)}${item.unit}';
      case ThemeSettingKind.select:
        vars[key] = value as String;
        flags.add('$key-$value');
      default:
        break;
    }
  }
  return ThemeSettingValues(vars: vars, flags: flags, values: values);
}

String? _lastSettingsSource;
ThemeSettingsSchema? _lastSettingsSchema;

extension ThemePresetSettings on ThemePreset {
  /// The theme's own Chat-screen declaration, or null for the built-in one.
  ThemeSettingsSchema? get settingsSchema {
    if (layoutSettings.isEmpty) return null;
    if (!identical(layoutSettings, _lastSettingsSource) &&
        layoutSettings != _lastSettingsSource) {
      _lastSettingsSource = layoutSettings;
      _lastSettingsSchema = ThemeSettingsSchema.parse(layoutSettings);
    }
    final schema = _lastSettingsSchema;
    return schema == null || schema.isEmpty ? null : schema;
  }

  ThemeSettingValues get settingValues =>
      themeSettingValues(settingsSchema, themeValues);

  /// [messageLayout] with the theme's setting values added, as the chat page
  /// takes it (`renderer/theme_layout.js`). Null when there is neither.
  Map<String, Object>? get messageLayoutPayload {
    final values = settingValues;
    final layout = messageLayout;
    if (layout == null && values.isEmpty) return null;
    return {...?layout, if (!values.isEmpty) ...values.toJson()};
  }

  /// [chromeLayout] with the theme's setting variables and flags added, as
  /// the chrome takes it (`chrome/index.js`, applySkin).
  Map<String, Object>? get chromeLayoutPayload {
    final values = settingValues;
    final layout = chromeLayout;
    if (layout == null && values.isEmpty) return null;
    return {
      ...?layout,
      if (!values.isEmpty) ...{'vars': values.vars, 'flags': values.flags},
    };
  }
}

/// Evaluates a row's or group's `when` condition.
///
/// The language is small on purpose: names, `'strings'`, numbers, `true`,
/// `false`, `null`, `!`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||` and
/// parentheses. [lookup] gives a name's value. A condition that does not
/// parse holds, so a typo shows a row rather than hiding it for good.
bool evaluateThemeCondition(
  String? expr,
  Object? Function(String name) lookup,
) {
  if (expr == null || expr.isEmpty) return true;
  try {
    final parser = _CondParser(expr, lookup);
    final v = parser.parse();
    return _truthy(v);
  } on FormatException {
    return true;
  }
}

bool _truthy(Object? v) =>
    v != null && v != false && v != 0 && v != '' && v != 0.0;

class _CondParser {
  _CondParser(this.src, this.lookup);

  final String src;
  final Object? Function(String name) lookup;
  int pos = 0;

  Object? parse() {
    final v = _or();
    _ws();
    if (pos != src.length) throw const FormatException('trailing input');
    return v;
  }

  void _ws() {
    while (pos < src.length && ' \t\n\r'.contains(src[pos])) {
      pos++;
    }
  }

  bool _eat(String token) {
    _ws();
    if (src.startsWith(token, pos)) {
      pos += token.length;
      return true;
    }
    return false;
  }

  Object? _or() {
    var left = _and();
    while (_eat('||')) {
      final right = _and();
      left = _truthy(left) || _truthy(right);
    }
    return left;
  }

  Object? _and() {
    var left = _cmp();
    while (_eat('&&')) {
      final right = _cmp();
      left = _truthy(left) && _truthy(right);
    }
    return left;
  }

  Object? _cmp() {
    final left = _unary();
    for (final op in const ['==', '!=', '<=', '>=', '<', '>']) {
      if (_eat(op)) {
        final right = _unary();
        switch (op) {
          case '==':
            return _eq(left, right);
          case '!=':
            return !_eq(left, right);
        }
        if (left is! num || right is! num) return false;
        return switch (op) {
          '<=' => left <= right,
          '>=' => left >= right,
          '<' => left < right,
          _ => left > right,
        };
      }
    }
    return left;
  }

  bool _eq(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    return a == b;
  }

  Object? _unary() {
    if (_eat('!')) return !_truthy(_unary());
    return _primary();
  }

  Object? _primary() {
    _ws();
    if (pos >= src.length) throw const FormatException('unexpected end');
    final c = src[pos];
    if (c == '(') {
      pos++;
      final v = _or();
      if (!_eat(')')) throw const FormatException('missing )');
      return v;
    }
    if (c == "'" || c == '"') {
      final end = src.indexOf(c, pos + 1);
      if (end < 0) throw const FormatException('unterminated string');
      final s = src.substring(pos + 1, end);
      pos = end + 1;
      return s;
    }
    final number = RegExp(r'-?\d+(\.\d+)?').matchAsPrefix(src, pos);
    if (number != null) {
      pos = number.end;
      return double.parse(number.group(0)!);
    }
    final name = RegExp(r'[A-Za-z_][A-Za-z0-9_.-]*').matchAsPrefix(src, pos);
    if (name != null) {
      pos = name.end;
      final n = name.group(0)!;
      switch (n) {
        case 'true':
          return true;
        case 'false':
          return false;
        case 'null':
          return null;
      }
      final v = lookup(n);
      return v is int ? v.toDouble() : v;
    }
    throw FormatException('unexpected "$c"');
  }
}
