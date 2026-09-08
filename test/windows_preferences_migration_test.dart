import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:glaze_flutter/core/services/windows_preferences_migration.dart';

void main() {
  late Directory appData;

  setUp(() async {
    appData = await Directory.systemTemp.createTemp('glaze_prefs_migration_');
  });

  tearDown(() async {
    if (await appData.exists()) await appData.delete(recursive: true);
  });

  test('merges legacy values over current values once', () async {
    final legacy = File(
      p.join(
        appData.path,
        'com.glaze',
        'glaze_flutter',
        'shared_preferences.json',
      ),
    );
    final current = File(
      p.join(appData.path, 'com.glaze', 'Glaze', 'shared_preferences.json'),
    );
    await legacy.parent.create(recursive: true);
    await current.parent.create(recursive: true);
    await legacy.writeAsString(jsonEncode({'theme': 'legacy', 'old': true}));
    await current.writeAsString(jsonEncode({'theme': 'default', 'new': true}));

    await migrateLegacyWindowsPreferences(
      environment: {'APPDATA': appData.path},
    );

    expect(jsonDecode(await current.readAsString()), {
      'theme': 'legacy',
      'old': true,
      'new': true,
    });

    await legacy.writeAsString(jsonEncode({'theme': 'changed'}));
    await migrateLegacyWindowsPreferences(
      environment: {'APPDATA': appData.path},
    );
    expect(
      (jsonDecode(await current.readAsString()) as Map)['theme'],
      'legacy',
    );
  });

  test(
    'does not replace current preferences when legacy JSON is invalid',
    () async {
      final legacy = File(
        p.join(
          appData.path,
          'com.glaze',
          'glaze_flutter',
          'shared_preferences.json',
        ),
      );
      final current = File(
        p.join(appData.path, 'com.glaze', 'Glaze', 'shared_preferences.json'),
      );
      await legacy.parent.create(recursive: true);
      await current.parent.create(recursive: true);
      await legacy.writeAsString('{invalid');
      await current.writeAsString(jsonEncode({'theme': 'current'}));

      await migrateLegacyWindowsPreferences(
        environment: {'APPDATA': appData.path},
      );

      expect(jsonDecode(await current.readAsString()), {'theme': 'current'});
    },
  );
}
