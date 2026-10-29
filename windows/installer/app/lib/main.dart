import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/args.dart';
import 'src/controller.dart';
import 'src/demo.dart';
import 'src/engine.dart';
import 'src/system.dart';
import 'ui/setup_window.dart';
import 'ui/strings.dart';

/// The Glaze setup window. Started by the launcher (windows/installer/launcher)
/// with the setup's own arguments; see [SetupArgs] for what they mean.
Future<void> main(List<String> argv) async {
  WidgetsFlutterBinding.ensureInitialized();
  final args = SetupArgs.parse(argv);
  final engine = args.demo ? _demoEngine(argv) : SetupEngine(WindowsSystem());
  final controller = SetupController(args: args, engine: engine);

  if (args.silent) {
    // Nobody to show anything to: run, and say how it went in the exit code.
    await controller.load();
    exit(controller.phase == SetupPhase.done ? 0 : 1);
  }

  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(780, 500),
      minimumSize: Size(780, 500),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
    ),
    () async {
      await windowManager.setTitle(S.of.windowTitle);
      await windowManager.setResizable(false);
      await windowManager.show();
      await windowManager.focus();
    },
  );

  runApp(
    SetupApp(
      controller: controller,
      hooks: WindowHooks(
        onClose: () => exit(controller.phase == SetupPhase.failed ? 1 : 0),
        onDrag: (_) => windowManager.startDragging(),
      ),
    ),
  );
  await controller.load();
}

/// `--demo` with `--demo-app-open`, `--demo-fail`, `--demo-previous <v>`.
DemoEngine _demoEngine(List<String> argv) {
  final previous = argv.indexOf('--demo-previous');
  return DemoEngine(
    appOpen: argv.contains('--demo-app-open'),
    fail: argv.contains('--demo-fail'),
    previousVersion: previous >= 0 && previous + 1 < argv.length
        ? argv[previous + 1]
        : null,
  );
}
