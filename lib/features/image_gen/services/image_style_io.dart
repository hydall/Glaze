import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';

import '../image_gen_models.dart';

/// JSON export / import for the style library.
///
/// The file is a plain, shareable document — ids are dropped on export and
/// regenerated on import so a style pasted from someone else can never collide
/// with a local one.
class ImageStyleIo {
  const ImageStyleIo._();

  static const kind = 'glaze-image-styles';
  static const version = 1;

  static String encode(List<ImageStyle> styles) =>
      const JsonEncoder.withIndent('  ').convert({
        'kind': kind,
        'version': version,
        'styles': styles
            .map((style) => {'name': style.name, 'value': style.value})
            .toList(),
      });

  /// Parses an exported file. Also accepts a bare list of styles and a single
  /// style object, so a hand-written snippet still imports.
  ///
  /// Throws [FormatException] with a readable message on anything else.
  static List<ImageStyle> decode(String raw) {
    final Object? payload;
    try {
      payload = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException(
        'imggen_styles_err_invalid_json'.tr(
          namedArgs: {'message': e.message},
        ),
      );
    }

    final List<Object?> entries;
    if (payload is List) {
      entries = payload;
    } else if (payload is Map) {
      final map = Map<String, dynamic>.from(payload);
      if (map['styles'] is List) {
        final declaredKind = map['kind'];
        if (declaredKind != null && declaredKind != kind) {
          throw FormatException(
            'imggen_styles_err_unsupported_kind'.tr(
              namedArgs: {'kind': '$declaredKind'},
            ),
          );
        }
        entries = map['styles'] as List;
      } else if (map.containsKey('value') || map.containsKey('name')) {
        entries = [map];
      } else {
        throw FormatException('imggen_styles_err_no_styles_array'.tr());
      }
    } else {
      throw FormatException('imggen_styles_err_unsupported_file'.tr());
    }

    final styles = <ImageStyle>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final value = (map['value'] as String? ?? '').trim();
      final name = (map['name'] as String? ?? '').trim();
      if (value.isEmpty && name.isEmpty) continue;
      styles.add(
        ImageStyle(
          id: newStyleId(),
          name: name.isEmpty ? 'Style ${styles.length + 1}' : name,
          value: value,
        ),
      );
    }
    if (styles.isEmpty) {
      throw FormatException('imggen_styles_err_no_styles'.tr());
    }
    return styles;
  }

  static String newStyleId() =>
      'style-${DateTime.now().microsecondsSinceEpoch}-'
      '${identityHashCode(Object()).toRadixString(36)}';

  /// `my_styles.glaze-styles.json` — safe on every target file system.
  static String fileName(String title) {
    final base = title
        .replaceAll(RegExp(r'[^\w\s.-]+'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    final normalized = base.isEmpty
        ? 'styles'
        : (base.length > 64 ? base.substring(0, 64) : base);
    return '$normalized.glaze-styles.json';
  }
}
