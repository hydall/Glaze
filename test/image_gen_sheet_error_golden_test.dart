import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_provider.dart';
import 'package:glaze_flutter/features/image_gen/widgets/image_gen_sheet.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/widgets/glaze_error_block.dart';

/// A rejected model listing in the image-gen sheet is shown through the shared
/// formatter in a [GlazeErrorBlock] — not as Dio's multi-paragraph dump in red
/// text, which is what a Naistera 401 used to produce.
///
/// The golden is opt-in, like the other golden tests (they only match the
/// machine that produced them):
///
///   GLAZE_GOLDENS=1 flutter test --update-goldens \
///     test/image_gen_sheet_error_golden_test.dart
final bool _runGoldens = Platform.environment['GLAZE_GOLDENS'] == '1';

Future<ByteData> _font(String path) async =>
    ByteData.view(Uint8List.fromList(File(path).readAsBytesSync()).buffer);

Future<void> _loadFonts() async {
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      _font(
        '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/fl/flutter'}'
        '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    );
  await icons.load();
  final inter = FontLoader('Inter')
    ..addFont(_font('assets/fonts/InterVariable.ttf'));
  await inter.load();
  // GlazeErrorBlock sets its message in `monospace`; without a face behind
  // that family the golden shows tofu instead of the text under test.
  const mono = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf';
  if (File(mono).existsSync()) {
    await (FontLoader('monospace')..addFont(_font(mono))).load();
  }
}

/// Settings held in memory: the sheet saves on every edit, and nothing here
/// should touch shared preferences.
class _StubSettings extends ImageGenSettingsNotifier {
  _StubSettings(this.initial);

  final ImageGenSettings initial;

  @override
  Future<ImageGenSettings> build() async => initial;

  @override
  Future<void> save(ImageGenSettings settings) async =>
      state = AsyncData(settings);
}

/// A local AUTOMATIC1111 stand-in that refuses every request the way a
/// `--api-auth` server does: 401 with a JSON `detail`.
Future<HttpServer> _rejectingServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response
      ..statusCode = HttpStatus.unauthorized
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'detail': 'missing bearer token'}));
    await request.response.close();
  });
  return server;
}

class _LoopbackOverrides extends HttpOverrides {
  _LoopbackOverrides(this.port);

  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..connectionFactory = (uri, proxyHost, proxyPort) =>
            Socket.startConnect(InternetAddress.loopbackIPv4, port);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await _loadFonts();
  });

  Future<void> pumpSheetAndFetch(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final server = await tester.runAsync(_rejectingServer);
    addTearDown(() => server!.close(force: true));

    // The test binding answers every HTTP request with a canned 400; the
    // point here is the real 401 body travelling through Dio. Connections are
    // routed to the loopback server so the endpoint field — which is in the
    // golden — shows a fixed address rather than an ephemeral port.
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _LoopbackOverrides(server!.port);
    addTearDown(() => HttpOverrides.global = previousOverrides);

    final settings = ImageGenSettings(
      enabled: true,
      apiType: ImageGenApiType.a1111,
      a1111: A1111ImageSettings(endpoint: 'http://a1111.local:7860'),
    );

    // The sheet reads the settings once in initState, so they must already be
    // loaded when it mounts.
    final container = ProviderContainer(
      overrides: [
        imageGenSettingsProvider.overrideWith(() => _StubSettings(settings)),
        activeApiConfigProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(
      () => container.read(imageGenSettingsProvider.future),
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: EasyLocalization(
            supportedLocales: const [Locale('en'), Locale('ru')],
            path: 'assets/translations',
            fallbackLocale: const Locale('en'),
            startLocale: const Locale('ru'),
            child: Builder(
              builder: (context) => MaterialApp(
                debugShowCheckedModeBanner: false,
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: AppTheme.dark(
                  const ThemePreset(id: 'default', name: 'Default'),
                  fontFamily: 'Inter',
                ),
                home: const Scaffold(body: ImageGenSheet()),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }

      await tester.tap(find.byIcon(Icons.refresh));
      // Real I/O: give the loopback round trip time to land.
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (find.byType(GlazeErrorBlock).evaluate().isNotEmpty) break;
      }
    });

    // Let the refresh button's ink splash fade, or the golden catches it at
    // whatever opacity the round trip happened to end on.
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('a rejected model listing reads as a formatted error block', (
    tester,
  ) async {
    await pumpSheetAndFetch(tester);

    final block = tester.widget<GlazeErrorBlock>(find.byType(GlazeErrorBlock));
    expect(block.message, startsWith('HTTP 401'));
    expect(block.message, contains('missing bearer token'));
    expect(block.message, isNot(contains('DioException')));
    expect(find.textContaining('RequestOptions.validateStatus'), findsNothing);
  });

  testWidgets('golden: image-gen sheet with a model-fetch error', (
    tester,
  ) async {
    await pumpSheetAndFetch(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/image_gen_sheet_fetch_error.png'),
    );
  }, skip: !_runGoldens);
}
