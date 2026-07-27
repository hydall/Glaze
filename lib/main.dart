import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/debug/perf_debug.dart';
import 'core/services/windows_preferences_migration.dart';

final appRestartKey = GlobalKey();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PerfDebug.installFrameLoggerIfEnabled();
  try {
    await migrateLegacyWindowsPreferences();
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'startup',
        context: ErrorDescription('Windows preferences migration failed'),
      ),
    );
  }
  await EasyLocalization.ensureInitialized();
  try {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'startup',
        context: ErrorDescription('orientation lock failed'),
      ),
    );
  }
  // Draw the app's own background behind the system status/navigation bars and
  // keep those bars transparent. Without this the OS paints the navigation bar
  // with the Android *window* background, which follows the system light/dark
  // setting (see android/.../values*/styles.xml). On a device whose OS is in
  // light mode while the app is forced dark (e.g. MIUI/HyperOS on Poco), that
  // left a light strip behind the navigation bar; some OEMs additionally force
  // a contrast scrim there. `edgeToEdge` + transparent bars + contrast disabled
  // lets [GlazeBackground] paint edge-to-edge instead. The floating nav bar and
  // other bottom UI already offset themselves by MediaQuery.padding.bottom.
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
        systemStatusBarContrastEnforced: false,
      ),
    );
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'startup',
        context: ErrorDescription('system UI overlay setup failed'),
      ),
    );
  }
  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('ru')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      child: const _RestartableApp(),
    ),
  );
}

class _RestartableApp extends StatefulWidget {
  const _RestartableApp();

  @override
  State<_RestartableApp> createState() => _RestartableAppState();
}

class _RestartableAppState extends State<_RestartableApp> {
  Key _key = UniqueKey();

  void restart() => setState(() => _key = UniqueKey());

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _key,
      child: ProviderScope(child: GlazeApp(restart: restart)),
    );
  }
}
