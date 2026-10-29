import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'args.dart';
import 'engine.dart';

enum SetupPhase { loading, welcome, working, done, failed }

/// The window's state: which page shows, where a run stands, and the choices
/// made on the first page. Runs the engine and is its listener.
class SetupController extends ChangeNotifier implements SetupListener {
  final SetupArgs args;
  final SetupEngine engine;

  /// How long an update waits for Glaze to quit on its own before it is
  /// closed. The in-app updater quits right after starting the setup, so this
  /// is only reached when something holds it up.
  final Duration updateGrace;

  SetupController({
    required this.args,
    required this.engine,
    this.updateGrace = const Duration(seconds: 20),
  });

  SetupMode get mode => args.mode;

  SetupPhase phase = SetupPhase.loading;
  InstallPaths? paths;

  /// Version of the install this one replaces, from its Apps entry.
  String? installedVersion;

  bool desktopShortcut = true;
  bool deleteData = false;
  bool canDeleteData = true;

  void setDesktopShortcut(bool value) {
    desktopShortcut = value;
    notifyListeners();
  }

  void setDeleteData(bool value) {
    deleteData = value;
    notifyListeners();
  }

  SetupStep? step;
  double progress = 0;
  String detail = '';
  Object? error;

  /// Glaze is running and holds the folder; the window offers to close it.
  bool waitingForApp = false;

  List<SetupStep> get steps => mode == SetupMode.uninstall
      ? [
          SetupStep.close,
          SetupStep.files,
          SetupStep.shortcuts,
          if (deleteData) SetupStep.data,
          SetupStep.finish,
        ]
      : const [
          SetupStep.close,
          SetupStep.files,
          SetupStep.shortcuts,
          SetupStep.finish,
        ];

  Future<void> load() async {
    try {
      paths = await engine.paths();
      final existing = await engine.existingInstall();
      installedVersion = existing?['DisplayVersion'];
      final shortcut = existing?['GlazeDesktopShortcut'];
      if (shortcut != null) desktopShortcut = shortcut == '1';
      if (mode == SetupMode.uninstall) {
        canDeleteData = await engine.canDeleteData();
      }
    } catch (e) {
      _fail(e);
      return;
    }
    phase = SetupPhase.welcome;
    notifyListeners();
    // An update was asked for by Glaze itself and a silent uninstall has
    // nobody to ask: neither waits on the first page.
    if (mode == SetupMode.update || args.silent) await start();
  }

  Future<void> start() async {
    phase = SetupPhase.working;
    step = null;
    progress = 0;
    detail = '';
    error = null;
    notifyListeners();
    try {
      if (mode == SetupMode.uninstall) {
        await engine.uninstall(deleteData: deleteData, listener: this);
      } else {
        final payload = args.payload;
        // The demo engine reads nothing.
        if (payload == null && !args.demo) throw const _NoPayload();
        await engine.install(
          payload: File(payload ?? ''),
          package: args.package == null ? null : File(args.package!),
          desktopShortcut: desktopShortcut,
          listener: this,
        );
      }
    } catch (e, st) {
      debugPrint('setup failed: $e\n$st');
      _fail(e);
      return;
    }
    phase = SetupPhase.done;
    notifyListeners();
  }

  void _fail(Object e) {
    error = e;
    waitingForApp = false;
    phase = SetupPhase.failed;
    notifyListeners();
  }

  bool get missingPayload => error is _NoPayload;

  Future<void> launchGlaze() async {
    final exe = paths?.exe;
    if (exe != null) await engine.system.launch(exe);
  }

  Future<void> closeGlazeNow() async {
    final p = paths;
    if (p != null) await engine.closeApp(p);
  }

  @override
  void onStep(SetupStep value) {
    step = value;
    notifyListeners();
  }

  @override
  void onProgress(double value) {
    // Many small files report thousands of times; a hundredth is all the
    // ring can show.
    if ((value - progress).abs() < 0.004 && value < 1) return;
    progress = value;
    notifyListeners();
  }

  @override
  void onDetail(String value) {
    if (value == detail) return;
    detail = value;
    notifyListeners();
  }

  @override
  Future<void> appRunning() async {
    final exe = paths!.exe;
    final started = DateTime.now();
    var asked = false;
    while (await engine.system.isRunning(exe)) {
      final waited = DateTime.now().difference(started);
      if (mode == SetupMode.update && waited > updateGrace) {
        await engine.closeApp(paths!);
      } else if (!asked && waited > const Duration(milliseconds: 1500)) {
        // A moment's grace first: Glaze closing on its own (the updater's
        // case) should not flash a question.
        asked = true;
        waitingForApp = true;
        notifyListeners();
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    if (waitingForApp) {
      waitingForApp = false;
      notifyListeners();
    }
  }
}

class _NoPayload implements Exception {
  const _NoPayload();

  @override
  String toString() => 'no Glaze build was passed to the setup (--payload)';
}
