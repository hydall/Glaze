import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'glossary_models.dart';

final glossaryProvider = FutureProvider.family<List<GlossaryCategory>, String>(
  (ref, lang) async {
    final asset = 'assets/translations/glossary_$lang.json';
    String raw;
    try {
      raw = await rootBundle.loadString(asset);
    } catch (_) {
      raw = await rootBundle.loadString('assets/translations/glossary_en.json');
    }
    final decoded = json.decode(raw) as Map<String, dynamic>;
    final cats = (decoded['categories'] as List?) ?? const [];
    return cats
        .cast<Map<String, dynamic>>()
        .map(GlossaryCategory.fromJson)
        .toList(growable: false);
  },
);
