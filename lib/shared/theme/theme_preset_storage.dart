import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../application/sync_theme_store.dart';
import 'theme_preset.dart';

abstract interface class ThemePresetStore {
  Future<List<ThemePreset>> loadAll();
  Future<String> loadActiveId();
  Future<void> saveAll(List<ThemePreset> presets);
  Future<ThemePreset> importFromFile(String path);
  Future<void> addPreset(ThemePreset preset);
  Future<void> removePreset(String id);
  Future<void> setActive(String id);
}

class ThemePresetStorage implements SyncThemePresetStore, ThemePresetStore {
  static const _presetsKey = 'theme_presets';
  static const _activeKey = 'theme_active_preset';

  final SharedPreferences _prefs;
  ThemePresetStorage(this._prefs);

  static Future<ThemePresetStorage> create() async {
    final prefs = await SharedPreferences.getInstance();
    return ThemePresetStorage(prefs);
  }

  /// Accent the built-in themes carried before the cherry rebrand. Matching on
  /// exactly this value lets the migration bump an untouched built-in without
  /// overwriting a theme the user changed by hand.
  static const _legacyDefaultAccent = '#7996CE';

  bool _builtinsChanged = false;

  @override
  Future<List<ThemePreset>> loadAll() async {
    final raw = _prefs.getString(_presetsKey);
    if (raw == null) return _withBuiltins([]);
    try {
      final list = jsonDecode(raw) as List;
      final presets = list
          .map((e) => themePresetFromStoredJson(e as Map<String, dynamic>))
          .toList();
      _builtinsChanged = false;
      final merged = _withBuiltins(presets);
      // The built-ins are written to storage on first run and kept as-is
      // afterwards, so a rebrand of the default accent would never reach an
      // install that already had a copy. Persist the re-accent once.
      if (_builtinsChanged) {
        await saveAll(merged);
      }
      return merged;
    } catch (_) {
      return _withBuiltins([]);
    }
  }

  /// Guarantee the built-in standard themes are always present and pinned to
  /// the top of the list (Default first, then Material You). Existing user
  /// copies of a built-in id are kept as-is so customised fonts/effects
  /// survive a reload — only an accent still sitting on the pre-rebrand default
  /// is moved to the current one.
  List<ThemePreset> _withBuiltins(List<ThemePreset> presets) {
    final result = List<ThemePreset>.from(presets);
    _seedOrReaccent(result, 'default', _defaultPreset, 0);
    final defaultIdx = result.indexWhere((p) => p.id == 'default');
    _seedOrReaccent(
      result,
      kMaterialYouPresetId,
      _materialYouPreset,
      defaultIdx + 1,
    );
    return result;
  }

  void _seedOrReaccent(
    List<ThemePreset> presets,
    String id,
    ThemePreset builtin,
    int insertAt,
  ) {
    final idx = presets.indexWhere((p) => p.id == id);
    if (idx == -1) {
      presets.insert(insertAt, builtin);
      _builtinsChanged = true;
      return;
    }
    final existing = presets[idx];
    if (existing.accentColor.toUpperCase() != _legacyDefaultAccent) return;
    if (existing.accentColor.toUpperCase() ==
        builtin.accentColor.toUpperCase()) {
      return;
    }
    presets[idx] = existing.copyWith(accentColor: builtin.accentColor);
    _builtinsChanged = true;
  }

  @override
  Future<String> loadActiveId() async {
    return _prefs.getString(_activeKey) ?? 'default';
  }

  @override
  Future<void> saveAll(List<ThemePreset> presets) async {
    await _prefs.setString(
      _presetsKey,
      jsonEncode(presets.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> saveActiveId(String id) async {
    await _prefs.setString(_activeKey, id);
  }

  @override
  Future<ThemePreset> importFromFile(String path) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final archive = _tryDecodeArchive(bytes);
    if (archive != null) {
      final archiveJson = _readThemeJsonFromArchive(archive);
      if (archiveJson != null) {
        return _fromThemeJson(archiveJson, archive: archive);
      }
    }

    final content = utf8.decode(bytes);
    final json = _decodeJsonObject(content);
    return _fromThemeJson(json);
  }

  Future<ThemePreset> importFromJson(String jsonStr) async {
    final json = _decodeJsonObject(jsonStr);
    return _fromThemeJson(json);
  }

  Map<String, dynamic> _decodeJsonObject(String content) {
    final value = jsonDecode(content);
    if (value is! Map) {
      throw const FormatException('Theme file must contain a JSON object');
    }
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  ThemePreset _fromThemeJson(Map<String, dynamic> json, {Archive? archive}) {
    final isSillyCradle = json['_type'] == 'silly_cradle_theme';
    final isTavo = json['spec'] == 'tavo_theme_v1';
    final isMoonlit = json['moonlitEchoesPreset'] == true;
    final isSillyTavern = _isSillyTavernTheme(json);
    if (!isSillyCradle &&
        !isTavo &&
        !isMoonlit &&
        !isSillyTavern &&
        json.containsKey('accentColor') == false) {
      throw const FormatException('Not a valid theme file');
    }

    if (isTavo) {
      return _fromTavoThemeJson(json, archive: archive);
    }
    if (isMoonlit) return _fromMoonlitThemeJson(json);
    if (isSillyTavern) return _fromSillyTavernThemeJson(json);

    final id = 'imported_${DateTime.now().millisecondsSinceEpoch}';
    final name = json['name'] as String? ?? 'Imported Theme';

    final stripped = Map<String, dynamic>.from(json)
      ..remove('_type')
      ..remove('id')
      ..remove('name');

    stripped['id'] = id;
    stripped['name'] = name;

    return themePresetFromStoredJson(stripped);
  }

  bool _isSillyTavernTheme(Map<String, dynamic> json) {
    const markers = [
      'main_text_color',
      'blur_tint_color',
      'user_mes_blur_tint_color',
      'bot_mes_blur_tint_color',
    ];
    return json['name'] is String &&
        markers.where(json.containsKey).length >= 3;
  }

  ThemePreset _fromMoonlitThemeJson(Map<String, dynamic> json) {
    final settings = _asMap(json['settings']);
    if (settings.isEmpty) {
      throw const FormatException('Moonlit Echoes theme has no settings');
    }
    final accent = _cssColor(settings['customThemeColor']) ?? '#C42A4A';
    final ui = _cssColor(settings['customTopBarColor']);
    final text = _cssColor(settings['customThemeColor2']);
    final userBubble = _cssColorWithAlpha(settings['customBgColor1']);
    final charBubble = _cssColorWithAlpha(settings['customBgColor2']);
    final shell = _parseCssColor(settings['sheldBackgroundColor']);

    return ThemePreset(
      id: 'imported_${DateTime.now().millisecondsSinceEpoch}',
      name: json['presetName'] is String
          ? json['presetName'] as String
          : 'Imported Moonlit Theme',
      author: 'Moonlit Echoes',
      themeMode: _guessThemeModeFromCss(
        settings['customTopBarColor'] ?? settings['sheldBackgroundColor'],
      ),
      accentColor: accent,
      uiColor: ui,
      bgColor: shell?.hex,
      userBubbleColor: userBubble,
      charBubbleColor: charBubble,
      userTextColor: text,
      charTextColor: text,
      uiTextColor: text,
      elementOpacity: shell?.alpha ?? 0.8,
      elementBlur: _cssNumber(settings['sheldBlurStrength']) ?? 0,
      chatFontSize: _cssNumber(settings['messageTextFontSize']) ?? 'system',
    );
  }

  ThemePreset _fromSillyTavernThemeJson(Map<String, dynamic> json) {
    final mainText = _cssColor(json['main_text_color']);
    final italic = _cssColor(json['italics_text_color']);
    final quote = _cssColor(json['quote_text_color']);
    final ui = _parseCssColor(json['blur_tint_color']);
    final border = _parseCssColor(json['border_color']);
    final userBubble = _cssColorWithAlpha(json['user_mes_blur_tint_color']);
    final charBubble = _cssColorWithAlpha(json['bot_mes_blur_tint_color']);

    return ThemePreset(
      id: 'imported_${DateTime.now().millisecondsSinceEpoch}',
      name: json['name'] as String,
      author: 'SillyTavern',
      themeMode: _guessThemeModeFromCss(json['blur_tint_color']),
      accentColor: quote ?? border?.hex ?? '#C42A4A',
      uiColor: ui?.hex,
      bgColor: _cssColor(json['chat_tint_color']),
      elementOpacity: ui?.alpha ?? 0.8,
      elementBlur: _asDouble(json['blur_strength']) ?? 0,
      userBubbleColor: userBubble,
      charBubbleColor: charBubble,
      userTextColor: mainText,
      charTextColor: mainText,
      userItalicColor: italic,
      charItalicColor: italic,
      userQuoteColor: quote,
      charQuoteColor: quote,
      uiTextColor: mainText,
      borderWidth: _asDouble(json['shadow_width']) ?? 1,
      borderColor: border?.hex,
      borderOpacity: border?.alpha ?? 0.1,
      showUserAvatar: !(_asBool(json['hideChatAvatars_enabled']) ?? false),
      showCharAvatar: !(_asBool(json['hideChatAvatars_enabled']) ?? false),
      hideMessageId: !(_asBool(json['mesIDDisplay_enabled']) ?? true),
      hideGenerationTime: !(_asBool(json['timer_enabled']) ?? true),
      hideTokenCount: !(_asBool(json['message_token_count_enabled']) ?? true),
    );
  }

  ({String hex, double alpha})? _parseCssColor(Object? value) {
    if (value is! String) return null;
    final match = RegExp(
      r'^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})(?:\s*,\s*(\d*\.?\d+))?\s*\)$',
      caseSensitive: false,
    ).firstMatch(value.trim());
    if (match == null) return null;
    final r = int.parse(match.group(1)!).clamp(0, 255);
    final g = int.parse(match.group(2)!).clamp(0, 255);
    final b = int.parse(match.group(3)!).clamp(0, 255);
    final alpha = (double.tryParse(match.group(4) ?? '1') ?? 1)
        .clamp(0.0, 1.0)
        .toDouble();
    final hex =
        '#${r.toRadixString(16).padLeft(2, '0')}'
                '${g.toRadixString(16).padLeft(2, '0')}'
                '${b.toRadixString(16).padLeft(2, '0')}'
            .toUpperCase();
    return (hex: hex, alpha: alpha);
  }

  String? _cssColor(Object? value) => _parseCssColor(value)?.hex;

  String? _cssColorWithAlpha(Object? value) {
    final color = _parseCssColor(value);
    if (color == null) return null;
    final alpha = (color.alpha * 255).round().clamp(0, 255);
    if (alpha == 255) return color.hex;
    return '#${alpha.toRadixString(16).padLeft(2, '0').toUpperCase()}'
        '${color.hex.substring(1)}';
  }

  double? _cssNumber(Object? value) {
    if (value is num) return value.toDouble();
    if (value is! String) return null;
    return double.tryParse(
      RegExp(r'-?\d+(?:\.\d+)?').firstMatch(value)?.group(0) ?? '',
    );
  }

  String _guessThemeModeFromCss(Object? value) {
    final color = _parseCssColor(value);
    if (color == null) return 'dark';
    final hex = color.hex.substring(1);
    final r = int.parse(hex.substring(0, 2), radix: 16);
    final g = int.parse(hex.substring(2, 4), radix: 16);
    final b = int.parse(hex.substring(4, 6), radix: 16);
    final luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
    return luminance > 0.55 ? 'light' : 'dark';
  }

  Archive? _tryDecodeArchive(Uint8List bytes) {
    try {
      return ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _readThemeJsonFromArchive(Archive archive) {
    try {
      final themeEntry = archive.findFile('theme.json');
      if (themeEntry == null || !themeEntry.isFile) return null;
      final content = utf8.decode(themeEntry.content as List<int>);
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  ThemePreset _fromTavoThemeJson(
    Map<String, dynamic> json, {
    Archive? archive,
  }) {
    final id = 'imported_${DateTime.now().millisecondsSinceEpoch}';
    final name = json['name'] as String? ?? 'Imported Tavo Theme';

    final background = _asMap(json['background']);
    final console = _asMap(json['console']);
    final thinking = _asMap(json['thinking']);
    final statusBar = _asMap(json['status_bar']);
    final userBubble = _asMap(json['user_bubble']);
    final characterBubble = _asMap(json['character_bubble']);
    final userFont = _asMap(json['user_bubble_font']);
    final characterFont = _asMap(json['character_bubble_font']);
    final userAvatar = _asMap(json['user_avatar']);
    final characterAvatar = _asMap(json['character_avatar']);
    final bubbleDisplayType = json['bubble_display_type'] as String?;
    final displayMode = json['display_mode'] as String?;

    final bgColorInt = _asInt(background['color']);
    final consoleBgInt = _asInt(console['color']);
    final thinkingBgInt = _asInt(thinking['backgroundColor']);
    final statusBgInt = _asInt(statusBar['backgroundColor']);
    final uiColorInt =
        consoleBgInt ?? statusBgInt ?? thinkingBgInt ?? bgColorInt;
    final userBubbleInt = _asInt(userBubble['color']);
    final charBubbleInt = _asInt(characterBubble['color']);
    final uiTextColorInt = _firstNonNullInt([
      _asInt(console['fontColor']),
      _asInt(statusBar['color']),
      _asInt(thinking['color']),
    ]);
    final uiTextGrayColorInt = _firstNonNullInt([
      _asInt(console['placeholderColor']),
      _asInt(statusBar['color']),
      _asInt(thinking['color']),
    ]);

    final bgColor = _hexOrNull(bgColorInt);
    final uiColor = _hexOrNull(uiColorInt);
    final accent =
        _hexOrNull(userBubbleInt) ??
        _hexOrNull(_asInt(console['sendColor'])) ??
        '#C42A4A';
    final bgImage = _resolveBackgroundImage(
      background['image'] as String?,
      archive,
    );
    // Tavo stores image visibility; Glaze darkens the background instead.
    final bgOpacity =
        _asDouble(background['imageOpacity']) ??
        _opacityFromArgb(bgColorInt) ??
        0.85;
    final bgDim = (1.0 - bgOpacity).clamp(0.0, 1.0).toDouble();
    final bgBlur = _asDouble(background['blur']) ?? 0;
    final elementBlur =
        _firstNonNullDouble([
          _asDouble(console['blur']),
          _averageDouble(
            _asDouble(userBubble['blur']),
            _asDouble(characterBubble['blur']),
          ),
        ]) ??
        12;
    final elementOpacity = _averageOpacity([
      consoleBgInt,
      statusBgInt,
      thinkingBgInt,
    ]);
    final borderColor =
        _hexOrNull(statusBgInt) ?? _hexOrNull(uiTextGrayColorInt) ?? uiColor;
    final borderOpacity = ((elementOpacity * 0.3).clamp(0.08, 0.25)).toDouble();
    final themeMode = _guessThemeMode(bgColorInt ?? uiColorInt);
    final chatLayout = _mapChatLayout(
      bubbleDisplayType: bubbleDisplayType,
      displayMode: displayMode,
    );
    final uiFontSize = _firstNonNullDouble([
      _asDouble(console['fontSize']),
      _asDouble(statusBar['fontSize']),
      _asDouble(thinking['fontSize']),
    ]);
    final chatFontSize = _averageFontSize(
      _asDouble(userFont['fontSize']),
      _asDouble(characterFont['fontSize']),
    );
    final borderWidth = _borderWidthFromOpacity(elementOpacity);
    final uiFontWeight =
        _firstNonNullInt([
          _normalizeFontWeight(console['fontWeight']),
          _normalizeFontWeight(statusBar['fontWeight']),
          _normalizeFontWeight(thinking['fontWeight']),
        ]) ??
        400;
    final userMessageFontWeight =
        _normalizeFontWeight(userFont['fontWeight']) ?? 400;
    final charMessageFontWeight =
        _normalizeFontWeight(characterFont['fontWeight']) ?? 400;
    final userBubbleRadius = _asDouble(userBubble['radius']) ?? 18;
    final charBubbleRadius = _asDouble(characterBubble['radius']) ?? 18;

    return ThemePreset(
      id: id,
      name: name,
      author: 'Tavo',
      themeMode: themeMode,
      accentColor: accent,
      bgDim: bgDim,
      bgBlur: bgBlur,
      elementOpacity: elementOpacity.clamp(0.0, 1.0).toDouble(),
      elementBlur: elementBlur,
      uiColor: uiColor,
      bgColor: bgColor,
      chatLayout: chatLayout,
      userBubbleColor: _hexOrNull(userBubbleInt),
      charBubbleColor: _hexOrNull(charBubbleInt),
      userQuoteColor: _hexOrNull(_asInt(userFont['quoteColor'])),
      charQuoteColor: _hexOrNull(_asInt(characterFont['quoteColor'])),
      userTextColor: _hexOrNull(_asInt(userFont['color'])),
      charTextColor: _hexOrNull(_asInt(characterFont['color'])),
      userItalicColor: _hexOrNull(_asInt(userFont['toneColor'])),
      charItalicColor: _hexOrNull(_asInt(characterFont['toneColor'])),
      uiFontSize: uiFontSize ?? 'system',
      uiFontWeight: uiFontWeight,
      chatFontSize: chatFontSize,
      userMessageFontWeight: userMessageFontWeight,
      charMessageFontWeight: charMessageFontWeight,
      uiTextColor: _hexOrNull(uiTextColorInt),
      uiTextGrayColor: _hexOrNull(uiTextGrayColorInt),
      borderWidth: borderWidth,
      borderColor: borderColor,
      borderOpacity: borderOpacity,
      userBubbleRadius: userBubbleRadius,
      charBubbleRadius: charBubbleRadius,
      showUserAvatar: _asBool(userAvatar['avatar']) ?? true,
      showCharAvatar: _asBool(characterAvatar['avatar']) ?? true,
      showUserName: _asBool(userAvatar['name']) ?? true,
      showCharName: _asBool(characterAvatar['name']) ?? true,
      bgImage: bgImage,
    );
  }

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, dynamic>{};
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  double? _asDouble(Object? value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return null;
  }

  bool? _asBool(Object? value) {
    if (value is bool) return value;
    return null;
  }

  int? _normalizeFontWeight(Object? value) {
    final raw = _asInt(value);
    if (raw == null) return null;
    if (raw <= 9) {
      return (raw * 100).clamp(100, 900);
    }
    return ((raw ~/ 100) * 100).clamp(100, 900);
  }

  int? _firstNonNullInt(List<int?> values) {
    for (final value in values) {
      if (value != null) return value;
    }
    return null;
  }

  double? _firstNonNullDouble(List<double?> values) {
    for (final value in values) {
      if (value != null) return value;
    }
    return null;
  }

  String? _hexOrNull(int? argb) {
    if (argb == null) return null;
    final hex = argb.toRadixString(16).padLeft(8, '0').toUpperCase();
    final a = hex.substring(0, 2);
    final rgb = hex.substring(2);
    return a == 'FF' ? '#$rgb' : '#$hex';
  }

  double? _opacityFromArgb(int? argb) {
    if (argb == null) return null;
    return ((argb >> 24) & 0xFF) / 255.0;
  }

  String _guessThemeMode(int? argb) {
    if (argb == null) return 'dark';
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    final luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
    return luminance > 0.55 ? 'light' : 'dark';
  }

  double _averageFontSize(double? a, double? b) {
    if (a != null && b != null) return (a + b) / 2;
    return a ?? b ?? 14;
  }

  double? _averageDouble(double? a, double? b) {
    if (a != null && b != null) return (a + b) / 2;
    return a ?? b;
  }

  double _averageOpacity(List<int?> argbValues) {
    final values = argbValues
        .map(_opacityFromArgb)
        .whereType<double>()
        .toList(growable: false);
    if (values.isEmpty) return 0.8;
    final sum = values.fold<double>(0, (total, value) => total + value);
    return sum / values.length;
  }

  String _mapChatLayout({
    required String? bubbleDisplayType,
    required String? displayMode,
  }) {
    final bubble = bubbleDisplayType?.toLowerCase();
    final display = displayMode?.toLowerCase();
    if (bubble == 'bubble' || display == 'bubble') {
      return 'bubble';
    }
    return 'default';
  }

  double _borderWidthFromOpacity(double elementOpacity) {
    if (elementOpacity >= 0.75) return 1;
    if (elementOpacity >= 0.45) return 1.25;
    return 1.5;
  }

  String? _resolveBackgroundImage(String? value, Archive? archive) {
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('data:')) return value;
    if (archive == null) return null;
    return _readArchiveFileAsDataUri(archive, value);
  }

  String? _readArchiveFileAsDataUri(Archive archive, String path) {
    final normalized = path.replaceAll('\\', '/');
    final baseName = normalized.split('/').last;
    final entry = archive.findFile(normalized) ?? archive.findFile(baseName);
    if (entry == null || !entry.isFile) return null;
    final bytes = entry.content as List<int>;
    final mime = _guessMimeType(entry.name);
    return 'data:$mime;base64,${base64Encode(bytes)}';
  }

  String _guessMimeType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    return 'application/octet-stream';
  }

  @override
  Future<void> addPreset(ThemePreset preset) async {
    final presets = await loadAll();
    final idx = presets.indexWhere((p) => p.id == preset.id);
    if (idx >= 0) {
      presets[idx] = preset;
    } else {
      presets.add(preset);
    }
    await saveAll(presets);
  }

  @override
  Future<void> removePreset(String id) async {
    if (id == 'default' || id == kMaterialYouPresetId) return;
    final presets = await loadAll();
    presets.removeWhere((p) => p.id == id);
    await saveAll(presets);
  }

  @override
  Future<void> setActive(String id) async {
    await saveActiveId(id);
  }

  @override
  Future<List<ThemePreset>> getAll() => loadAll();

  @override
  Future<void> putAll(List<ThemePreset> presets) => saveAll(presets);
}

final _defaultPreset = ThemePreset(
  id: 'default',
  name: 'Default',
  accentColor: '#C42A4A',
  bgDim: 0.15,
  elementOpacity: 0.8,
  elementBlur: 12,
  chatLayout: 'default',
  borderWidth: 1,
  borderOpacity: 0.1,
  noiseOpacity: 0.03,
  noiseIntensity: 0.8,
  bgNoiseOpacity: 0.03,
  bgNoiseIntensity: 0.4,
);

/// Built-in "Material You" standard theme. Colors are resolved from the system
/// dynamic palette (Android) or a seed fallback at theme-build time, so the
/// stored `accentColor`/bubble fields here are only placeholders — they are
/// ignored when the theme is rendered. Fonts and background/element effects
/// remain user-editable.
final _materialYouPreset = ThemePreset(
  id: kMaterialYouPresetId,
  name: 'Material You',
  accentColor: '#C42A4A',
  bgDim: 0.15,
  elementOpacity: 0.8,
  elementBlur: 12,
  chatLayout: 'default',
  borderWidth: 1,
  borderOpacity: 0.1,
  noiseOpacity: 0.03,
  noiseIntensity: 0.8,
  bgNoiseOpacity: 0.03,
  bgNoiseIntensity: 0.4,
);
