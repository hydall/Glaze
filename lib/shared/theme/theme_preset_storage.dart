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

  @override
  Future<List<ThemePreset>> loadAll() async {
    final raw = _prefs.getString(_presetsKey);
    if (raw == null) return _withBuiltins([]);
    try {
      final list = jsonDecode(raw) as List;
      final presets = list
          .map((e) => ThemePreset.fromJson(e as Map<String, dynamic>))
          .toList();
      return _withBuiltins(presets);
    } catch (_) {
      return _withBuiltins([]);
    }
  }

  /// Guarantee the built-in standard themes are always present and pinned to
  /// the top of the list (Default first, then Material You). Existing user
  /// copies of a built-in id are kept as-is so customised fonts/effects
  /// survive a reload.
  List<ThemePreset> _withBuiltins(List<ThemePreset> presets) {
    final result = List<ThemePreset>.from(presets);
    if (!result.any((p) => p.id == 'default')) {
      result.insert(0, _defaultPreset);
    }
    if (!result.any((p) => p.id == kMaterialYouPresetId)) {
      final defaultIdx = result.indexWhere((p) => p.id == 'default');
      result.insert(defaultIdx + 1, _materialYouPreset);
    }
    return result;
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
    final json = jsonDecode(content) as Map<String, dynamic>;
    return _fromThemeJson(json);
  }

  Future<ThemePreset> importFromJson(String jsonStr) async {
    final json = jsonDecode(jsonStr) as Map<String, dynamic>;
    return _fromThemeJson(json);
  }

  ThemePreset _fromThemeJson(Map<String, dynamic> json, {Archive? archive}) {
    final isSillyCradle = json['_type'] == 'silly_cradle_theme';
    final isTavo = json['spec'] == 'tavo_theme_v1';
    if (!isSillyCradle && !isTavo && json.containsKey('accentColor') == false) {
      throw const FormatException('Not a valid theme file');
    }

    if (isTavo) {
      return _fromTavoThemeJson(json, archive: archive);
    }

    final id = 'imported_${DateTime.now().millisecondsSinceEpoch}';
    final name = json['name'] as String? ?? 'Imported Theme';

    final stripped = Map<String, dynamic>.from(json)
      ..remove('_type')
      ..remove('id')
      ..remove('name');

    stripped['id'] = id;
    stripped['name'] = name;

    return ThemePreset.fromJson(stripped);
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

  ThemePreset _fromTavoThemeJson(Map<String, dynamic> json, {Archive? archive}) {
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
    final accent = _hexOrNull(userBubbleInt) ??
        _hexOrNull(_asInt(console['sendColor'])) ??
        '#7996CE';
    final bgImage =
        _resolveBackgroundImage(background['image'] as String?, archive);
    final bgOpacity = _asDouble(background['imageOpacity']) ??
        _opacityFromArgb(bgColorInt) ??
        0.85;
    final bgBlur = _asDouble(background['blur']) ?? 0;
    final elementBlur = _firstNonNullDouble([
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
    final borderColor = _hexOrNull(statusBgInt) ?? _hexOrNull(uiTextGrayColorInt) ?? uiColor;
    final borderOpacity =
        ((elementOpacity * 0.3).clamp(0.08, 0.25)).toDouble();
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
    final uiFontWeight = _firstNonNullInt([
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
      bgOpacity: bgOpacity.clamp(0.0, 1.0).toDouble(),
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
      return value.map(
        (key, value) => MapEntry(key.toString(), value),
      );
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
    final luminance =
        (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
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
  accentColor: '#7996CE',
  bgOpacity: 0.85,
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
  accentColor: '#7996CE',
  bgOpacity: 0.85,
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
