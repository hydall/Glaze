import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final prefixes = [
    'agent_ops_',
    'prompt_inspector_studio_',
    'card_rewriter_studio_',
    'rewrite_resume',
  ];

  test('Agent Ops localization keys match in EN, RU, and generated keys', () {
    final en = _loadTranslations('assets/translations/en.json');
    final ru = _loadTranslations('assets/translations/ru.json');
    final generated = File(
      'lib/generated/locale_keys.g.dart',
    ).readAsStringSync();
    final keys = en.keys.where((key) => prefixes.any(key.startsWith)).toSet();

    expect(keys, isNotEmpty);
    expect(ru.keys.where((key) => prefixes.any(key.startsWith)).toSet(), keys);

    for (final key in keys) {
      expect(
        _placeholders(en[key]!),
        _placeholders(ru[key]!),
        reason: 'Placeholder mismatch for $key',
      );
      expect(
        generated,
        contains("static const $key = '$key';"),
        reason: '$key is missing from locale_keys.g.dart',
      );
    }
  });
}

Map<String, String> _loadTranslations(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync()) as Map;
  return decoded.map((key, value) => MapEntry('$key', '$value'));
}

Set<String> _placeholders(String value) => RegExp(
  r'\{([A-Za-z][A-Za-z0-9_]*)\}',
).allMatches(value).map((match) => match.group(1)!).toSet();
