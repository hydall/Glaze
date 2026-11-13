@TestOn('windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_setup/src/system.dart';

/// The real Windows side, against the registry of the machine running the
/// tests: a scratch key under HKCU\Software, removed again at the end.
void main() {
  final system = WindowsSystem();
  final key =
      'Software\\GlazeSetupTest\\${DateTime.now().microsecondsSinceEpoch}';

  tearDown(() => system.deleteKey(key));

  test('a key that does not exist reads as null, not as a failure', () async {
    // The first install of a channel: no Apps entry yet.
    expect(await system.readKey(key), isNull);
  });

  test('values written come back as text, with the name intact', () async {
    await system.writeKey(key, {
      'DisplayName': 'Glaze Nightly',
      'InstallLocation': r'C:\Users\Пользователь\AppData\Local\Programs',
      'NoModify': 1,
    });
    final read = await system.readKey(key);
    expect(read?['DisplayName'], 'Glaze Nightly');
    expect(
      read?['InstallLocation'],
      r'C:\Users\Пользователь\AppData\Local\Programs',
    );
    expect(read?['NoModify'], '1');
    expect(read?.keys, isNot(contains(startsWith('PS'))));
    expect(await system.keyExists(key), isTrue);
  });

  test('a deleted key is gone', () async {
    await system.writeKey(key, {'DisplayName': 'x'});
    await system.deleteKey(key);
    expect(await system.readKey(key), isNull);
    expect(await system.keyExists(key), isFalse);
  });
}
