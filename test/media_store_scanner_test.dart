import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/media_store_scanner.dart';

/// A backup written into public Downloads is on disk either way; what this
/// decides is whether the system picker's "Downloads" shortcut can see it,
/// because that shortcut lists Android's media database and not the directory.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('app.glaze.flutter/media_store');
  final calls = <MethodCall>[];

  void handleWith(Future<Object?>? Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler == null ? null : await handler(call);
    });
  }

  setUp(() {
    calls.clear();
    handleWith(null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a written export is handed to the media scanner', () async {
    await registerWithMediaStore('/storage/emulated/0/Download/Glaze/a.glz');

    expect(calls, hasLength(1));
    expect(calls.single.method, 'scanFile');
    expect(calls.single.arguments, {
      'path': '/storage/emulated/0/Download/Glaze/a.glz',
    });
  });

  test('nothing is scanned when nothing was written', () async {
    // The export helpers return the empty string for a cancelled save.
    await registerWithMediaStore('');

    expect(calls, isEmpty);
  });

  test('a platform that refuses the scan does not fail the export', () async {
    // The file is already written by the time this runs — an unregistered
    // export is worth more than an export reported as failed.
    handleWith((_) => throw PlatformException(code: 'no_media_provider'));
    await registerWithMediaStore('/storage/emulated/0/Download/Glaze/a.glz');

    handleWith((_) => throw MissingPluginException());
    await registerWithMediaStore('/storage/emulated/0/Download/Glaze/a.glz');

    expect(calls, hasLength(2));
  });
}
