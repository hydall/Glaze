import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_scaffold.dart';

/// Settings that never touch SharedPreferences.
class _StubSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

/// Stands in for the chat body: its State is what an `InAppWebView` holds on
/// to, and building a second one is what took the chat's WebView away.
class _Probe extends StatefulWidget {
  const _Probe();

  static int created = 0;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.created++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _Probe.created = 0;
  });

  // The chat screen drops the scaffold background once its body paints the
  // background image itself, so `showBackground` flips while the chat is open.
  // Wrapping the scaffold in GlazeBackground or not used to rebuild the whole
  // body under it — for the chat a second WebView widget taking over the shared
  // keep-alive WebView while the first was still mounted, which left the page
  // detached and blank, or reloaded it.
  testWidgets('toggling showBackground keeps the body it wraps', (
    tester,
  ) async {
    final showBackground = ValueNotifier(true);
    addTearDown(showBackground.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsProvider.overrideWith(_StubSettings.new)],
        child: MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: showBackground,
            builder: (_, show, _) => GlazeScaffold(
              title: 'Chat',
              showBackground: show,
              extendBodyBehindHeader: true,
              body: const _Probe(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final body = tester.state(find.byType(_Probe));

    showBackground.value = false;
    await tester.pump();
    expect(tester.state(find.byType(_Probe)), same(body));

    showBackground.value = true;
    await tester.pump();
    expect(tester.state(find.byType(_Probe)), same(body));
    expect(_Probe.created, 1, reason: 'the body was built more than once');
  });
}
