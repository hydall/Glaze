import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/app_runtime.dart';
import 'core/debug/perf_debug.dart';
import 'core/platform/desktop_window.dart';
import 'core/services/dev_mode_flag_migration.dart';
import 'core/services/preset_seeder.dart';
import 'core/services/windows_preferences_migration.dart';
import 'shared/shell/desktop/desktop_layout_provider.dart';

final appRestartKey = GlobalKey();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppRuntime.markStarted();
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
  // After the Windows migration: that one rewrites the preferences file on
  // disk, so it has to land before SharedPreferences is first opened here.
  try {
    await resetLegacyDevModeFlag();
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'startup',
        context: ErrorDescription('dev mode flag reset failed'),
      ),
    );
  }
  // Before the app opens: it reads `activePresetId` during startup, and a
  // first run has to find the choice already made rather than watch it change
  // underneath the first frames.
  try {
    await applyFirstRunPresetChoice();
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'startup',
        context: ErrorDescription('first-run preset choice failed'),
      ),
    );
  }
  await EasyLocalization.ensureInitialized();
  try {
    await initDesktopWindow();
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'startup',
        context: ErrorDescription('desktop window setup failed'),
      ),
    );
  }
  // Phones are locked to portrait; tablets may rotate, and it is the landscape
  // width that then turns on the desktop layout. No widget exists yet, so read
  // the first view's physical size and divide by its density to tell the two
  // apart. An unreadable size keeps the phone lock.
  try {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    var isTablet = false;
    if (views.isNotEmpty) {
      final view = views.first;
      final dpr = view.devicePixelRatio;
      if (dpr > 0) {
        final logical = view.physicalSize / dpr;
        isTablet = logical.shortestSide >= kTabletShortestSideBreakpoint;
      }
    }
    await SystemChrome.setPreferredOrientations(
      isTablet
          ? DeviceOrientation.values
          : const [
              DeviceOrientation.portraitUp,
              DeviceOrientation.portraitDown,
            ],
    );
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
