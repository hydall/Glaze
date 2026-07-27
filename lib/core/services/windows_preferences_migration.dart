import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const _legacyProductName = 'glaze_flutter';
const _currentProductName = 'Glaze';
const _migrationMarkerName = '.windows-prefs-product-name-v1';

Future<void> migrateLegacyWindowsPreferences({
  Map<String, String>? environment,
}) async {
  if (!Platform.isWindows && environment == null) return;

  final appData = (environment ?? Platform.environment)['APPDATA'];
  if (appData == null || appData.isEmpty) return;

  final marker = File(p.join(appData, 'Glaze', _migrationMarkerName));
  if (await marker.exists()) return;

  final legacy = File(
    p.join(appData, 'com.glaze', _legacyProductName, 'shared_preferences.json'),
  );
  final current = File(
    p.join(
      appData,
      'com.glaze',
      _currentProductName,
      'shared_preferences.json',
    ),
  );

  if (await legacy.exists()) {
    final legacyValues = await _readPreferences(legacy);
    final currentValues = await _readPreferences(current);
    if (legacyValues != null) {
      await current.parent.create(recursive: true);
      await _replaceJsonFile(current, {...?currentValues, ...legacyValues});
    }
  }

  await marker.parent.create(recursive: true);
  await marker.writeAsString('done', flush: true);
}

Future<Map<String, dynamic>?> _readPreferences(File file) async {
  if (!await file.exists()) return <String, dynamic>{};
  try {
    final decoded = jsonDecode(await file.readAsString());
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } on FormatException {
    return null;
  }
}

Future<void> _replaceJsonFile(
  File destination,
  Map<String, dynamic> values,
) async {
  final temporary = File('${destination.path}.migration.tmp');
  await temporary.writeAsString(jsonEncode(values), flush: true);

  final backup = File('${destination.path}.before-product-name-migration');
  if (await destination.exists()) {
    if (await backup.exists()) await backup.delete();
    await destination.rename(backup.path);
  }
  try {
    await temporary.rename(destination.path);
  } catch (_) {
    if (await backup.exists() && !await destination.exists()) {
      await backup.rename(destination.path);
    }
    rethrow;
  }
}
