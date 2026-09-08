import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/platform/wallpaper.dart';
import '../theme/theme_provider.dart';
import '../theme/theme_preset.dart';

const String _kInterFontFamily = 'Inter';
const String _kInterAssetPath = 'assets/fonts/InterVariable.ttf';

String? _cachedInterDataUrl;
Future<String?>? _interLoadFuture;

Future<String?> _loadInterDataUrl() async {
  if (_cachedInterDataUrl != null) return _cachedInterDataUrl;
  _interLoadFuture ??= () async {
    try {
      final data = await rootBundle.load(_kInterAssetPath);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      _cachedInterDataUrl = 'data:font/ttf;base64,${base64Encode(bytes)}';
      return _cachedInterDataUrl;
    } catch (_) {
      return null;
    }
  }();
  return _interLoadFuture;
}

/// Resolves the effective chat font mode, following the 'ui' delegation.
String _effectiveChatFontMode(ThemePreset preset) {
  if (preset.chatFontMode == 'ui') return preset.uiFontMode;
  return preset.chatFontMode;
}

final chatFontSizeProvider = Provider<double>((ref) {
  final preset = ref.watch(themeProvider).activePreset;
  return preset.chatFontSizeValue;
});

final chatLetterSpacingProvider = Provider<double>((ref) {
  final preset = ref.watch(themeProvider).activePreset;
  return preset.chatLetterSpacing;
});

class ChatFontStyle {
  final double fontSize;
  final double letterSpacing;
  final String? fontFamily;
  const ChatFontStyle({
    required this.fontSize,
    required this.letterSpacing,
    this.fontFamily,
  });
}

final chatFontStyleProvider = Provider<ChatFontStyle>((ref) {
  final preset = ref.watch(themeProvider).activePreset;
  return ChatFontStyle(
    fontSize: preset.chatFontSizeValue,
    letterSpacing: preset.chatLetterSpacing,
    fontFamily: ref.watch(chatFontFamilyProvider).value,
  );
});

final uiFontSizeProvider = Provider<double?>((ref) {
  final preset = ref.watch(themeProvider).activePreset;
  final v = preset.uiFontSize;
  if (v == 'system' || v == null) return null;
  return preset.uiFontSizeValue;
});

final uiLetterSpacingProvider = Provider<double>((ref) {
  final preset = ref.watch(themeProvider).activePreset;
  return preset.uiLetterSpacing;
});

final _loadedFonts = <String>{};

Uint8List? _extractFontBytes(String dataUri) {
  String base64Str;
  final commaIdx = dataUri.indexOf(',');
  if (commaIdx != -1) {
    base64Str = dataUri.substring(commaIdx + 1);
  } else {
    base64Str = dataUri;
  }

  try {
    final bytes = base64Decode(base64Str);

    // Validate: real font files start with known magic bytes
    // TrueType: 0x00 0x01 0x00 0x00
    // OpenType/CFF: 'OTTO'
    // WOFF: 'wOFF'
    // WOFF2: 'wOF2'
    // TrueType Collection: 'ttcf'
    if (bytes.length < 4) return null;
    final b0 = bytes[0], b1 = bytes[1], b2 = bytes[2], b3 = bytes[3];
    final isTtf = b0 == 0x00 && b1 == 0x01 && b2 == 0x00 && b3 == 0x00;
    final isOtf = b0 == 0x4F && b1 == 0x54 && b2 == 0x54 && b3 == 0x4F; // OTTO
    final isWoff = b0 == 0x77 && b1 == 0x4F && b2 == 0x46 && b3 == 0x46; // wOFF
    final isWoff2 =
        b0 == 0x77 && b1 == 0x4F && b2 == 0x46 && b3 == 0x32; // wOF2
    final isTtc = b0 == 0x74 && b1 == 0x74 && b2 == 0x63 && b3 == 0x66; // ttcf

    if (!isTtf && !isOtf && !isWoff && !isWoff2 && !isTtc) return null;

    return bytes;
  } catch (_) {
    return null;
  }
}

Future<String?> _loadFontFromBase64(String dataUri, String name) async {
  if (_loadedFonts.contains(name)) return name;

  try {
    final bytes = _extractFontBytes(dataUri);
    if (bytes == null) return null;

    await ui.loadFontFromList(bytes, fontFamily: name);
    _loadedFonts.add(name);
    return name;
  } catch (_) {
    return null;
  }
}

final chatFontFamilyProvider = FutureProvider<String?>((ref) async {
  final settings = ref.watch(themeProvider);
  if (settings.ignoreCustomFont) return null;
  final preset = settings.activePreset;
  final mode = _effectiveChatFontMode(preset);
  if (mode == 'glaze') return _kInterFontFamily;
  if (mode == 'custom') {
    if (!preset.hasChatFont || preset.chatFontName == null) return null;
    return _loadFontFromBase64(preset.chatFont!, preset.chatFontName!);
  }
  if (mode == 'google') {
    final chatGoogle = preset.chatGoogleFontName;
    final uiGoogle = preset.googleFontName;
    final fontName = chatGoogle ?? uiGoogle;
    if (fontName == null || fontName.isEmpty) return null;
    return _loadGoogleFont(fontName);
  }
  return null;
});

final chatFontDataProvider = FutureProvider<String?>((ref) async {
  final settings = ref.watch(themeProvider);
  if (settings.ignoreCustomFont) return null;
  final preset = settings.activePreset;
  final mode = _effectiveChatFontMode(preset);
  if (mode == 'glaze') return _loadInterDataUrl();
  if (mode == 'custom') {
    if (!preset.hasChatFont) return null;
    return preset.chatFont;
  }
  return null;
});

final uiFontFamilyProvider = FutureProvider<String?>((ref) async {
  final settings = ref.watch(themeProvider);
  if (settings.ignoreCustomFont) return null;
  final preset = settings.activePreset;
  final mode = preset.uiFontMode;
  if (mode == 'glaze') {
    unawaited(_loadInterDataUrl());
    return _kInterFontFamily;
  }
  if (mode == 'custom') {
    if (!preset.hasCustomFont || preset.customFontName == null) return null;
    return _loadFontFromBase64(preset.customFont!, preset.customFontName!);
  }
  if (mode == 'google') {
    final fontName = preset.googleFontName;
    if (fontName == null || fontName.isEmpty) return null;
    return _loadGoogleFont(fontName);
  }
  return null;
});

final _loadedGoogleFonts = <String>{};

Future<String?> _loadGoogleFont(String fontName) async {
  if (_loadedGoogleFonts.contains(fontName)) return fontName;
  try {
    final font = GoogleFonts.getFont(fontName);
    if (font.fontFamily != null) {
      _loadedGoogleFonts.add(fontName);
      return font.fontFamily;
    }
  } catch (_) {}
  return null;
}

/// Decoded background image bytes for native Flutter rendering. Returns null
/// when the active preset has no image. Recomputed only when the data URI
/// itself changes; `MemoryImage` caches the decoded pixels keyed by identity.
final bgImageBytesProvider = Provider<Uint8List?>((ref) {
  final preset = ref.watch(themeProvider).activePreset;
  if (!preset.hasBgImage) return null;
  return _decodeDataUri(preset.bgImage);
});

/// Decoded bytes for the chat-area custom background image
/// (`chatBgMode == 'custom'`). Null when unset or undecodable.
final chatBgImageBytesProvider = Provider<Uint8List?>((ref) {
  final preset = ref.watch(themeProvider).activePreset;
  if (!preset.hasChatBgImage) return null;
  return _decodeDataUri(preset.chatBgImage);
});

Uint8List? _decodeDataUri(String? data) {
  if (data == null) return null;
  try {
    final commaIdx = data.indexOf(',');
    if (commaIdx == -1) return null;
    return base64Decode(data.substring(commaIdx + 1));
  } catch (_) {
    return null;
  }
}

/// Device wallpaper bytes, used as the background for the Material You theme.
/// Android-only (the only platform where Material You sources dynamic color);
/// null elsewhere or when the wallpaper can't be read. Fetched lazily — the
/// permission prompt only fires once this provider is first watched (i.e. when
/// a Material You preset is active).
final wallpaperBytesProvider = FutureProvider<Uint8List?>((ref) async {
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  return Wallpaper.getWallpaper();
});

/// The background image bytes actually rendered by [GlazeBackground] and the
/// chat's `inherit` background. An explicit preset background image always
/// wins; otherwise the Material You theme falls back to the device wallpaper.
final effectiveBgImageBytesProvider = Provider<Uint8List?>((ref) {
  final explicit = ref.watch(bgImageBytesProvider);
  if (explicit != null) return explicit;
  final preset = ref.watch(themeProvider).activePreset;
  if (preset.isMaterialYou) {
    return ref.watch(wallpaperBytesProvider).value;
  }
  return null;
});
