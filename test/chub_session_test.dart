import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/chub_session.dart';

void main() {
  group('parseChubSessionProbe', () {
    test('reads a decoded map', () {
      final session = parseChubSessionProbe({'token': 't', 'user': 'neo'});
      expect(session?.token, 't');
      expect(session?.userName, 'neo');
    });

    test('reads the JSON string the probe returns', () {
      final session = parseChubSessionProbe(
        jsonEncode({'token': 't', 'user': 'neo'}),
      );
      expect(session?.token, 't');
      expect(session?.userName, 'neo');
    });

    test('unwraps Android double-quoting', () {
      final session = parseChubSessionProbe(
        jsonEncode(jsonEncode({'token': 't', 'user': null})),
      );
      expect(session?.token, 't');
      expect(session?.userName, isNull);
    });

    test('a missing or blank token is not a session', () {
      expect(parseChubSessionProbe(null), isNull);
      expect(parseChubSessionProbe(''), isNull);
      expect(parseChubSessionProbe('null'), isNull);
      expect(parseChubSessionProbe({'token': ''}), isNull);
      expect(parseChubSessionProbe({'user': 'neo'}), isNull);
    });

    test('garbage is not a session', () {
      expect(parseChubSessionProbe('not json'), isNull);
      expect(parseChubSessionProbe(42), isNull);
      expect(parseChubSessionProbe(['t']), isNull);
      expect(parseChubSessionProbe({'token': 7}), isNull);
    });
  });
}
