import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_provider.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_settings_codec.dart';
import 'package:glaze_flutter/features/image_gen/widgets/image_gen_sheet.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_spinner.dart';
import 'package:glaze_flutter/shared/widgets/glaze_switch.dart';

/// Opened from Tools on a cold start, the image-gen sheet mounted before the
/// settings provider had read shared preferences, showed the defaults, and the
/// first edit saved them over the stored settings — styles, references and
/// keys gone. Shared preferences are held back by a completer here so the
/// sheet is guaranteed to mount while the settings are still loading.
const _key = 'gz_imggen_settings';

const _stored = ImageGenSettings(
  enabled: true,
  customApiKey: 'sk-stored',
  styles: [ImageStyle(id: 'style-1', name: 'Watercolor', value: 'soft')],
  activeStyleId: 'style-1',
);

ImageGenSettings _readStored(SharedPreferences prefs) =>
    ImageGenSettingsCodec.fromJson(
      jsonDecode(prefs.getString(_key)!) as Map<String, dynamic>,
    );

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      _key: jsonEncode(ImageGenSettingsCodec.toJson(_stored)),
    });
    prefs = await SharedPreferences.getInstance();
  });

  // Created inside each test: a completer made in setUp lives outside the
  // widget test's fake-async zone, and its callbacks never run on pump().
  List<Override> overrides(Completer<SharedPreferences> prefsGate) => [
    sharedPreferencesProvider.overrideWith((ref) => prefsGate.future),
    activeApiConfigProvider.overrideWithValue(null),
  ];

  testWidgets('the sheet offers nothing to edit until the settings load', (
    tester,
  ) async {
    final prefsGate = Completer<SharedPreferences>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(prefsGate),
        child: const MaterialApp(home: Scaffold(body: ImageGenSheet())),
      ),
    );
    await tester.pump();

    expect(find.byType(GlazeSpinner), findsOneWidget);
    expect(find.byType(GlazeSwitch), findsNothing);

    // pumpAndSettle would wait on the spinner forever.
    prefsGate.complete(prefs);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The body has switches of its own; the enable switch is the top one, in
    // the header.
    final switches = find.byType(GlazeSwitch).evaluate().toList()
      ..sort(
        (a, b) => tester
            .getTopLeft(find.byElementPredicate((e) => e == a))
            .dy
            .compareTo(
              tester.getTopLeft(find.byElementPredicate((e) => e == b)).dy,
            ),
      );
    final toggle = find.byElementPredicate((e) => e == switches.first);
    expect(
      tester.widget<GlazeSwitch>(toggle).value,
      isTrue,
      reason: 'the stored settings, not the defaults',
    );

    await tester.tap(toggle);
    await tester.pump();

    final saved = _readStored(prefs);
    expect(saved.enabled, isFalse);
    expect(saved.styles, _stored.styles);
    expect(saved.activeStyleId, 'style-1');
    expect(saved.customApiKey, 'sk-stored');
  });

  test('updateEnabled before the settings load keeps the rest', () async {
    final prefsGate = Completer<SharedPreferences>();
    final container = ProviderContainer(overrides: overrides(prefsGate));
    addTearDown(container.dispose);
    final sub = container.listen(imageGenSettingsProvider, (_, _) {});
    addTearDown(sub.close);

    final update = container
        .read(imageGenSettingsProvider.notifier)
        .updateEnabled(false);
    prefsGate.complete(prefs);
    await update;

    final saved = _readStored(prefs);
    expect(saved.enabled, isFalse);
    expect(saved.styles, _stored.styles);
    expect(saved.customApiKey, 'sk-stored');
  });
}
