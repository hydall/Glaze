import 'dart:async';
import 'dart:io';

import 'engine.dart';
import 'system.dart';

/// `--demo`: every page and step of a real run, against nothing. For previews
/// of the window on any platform and for widget tests.
class DemoEngine extends SetupEngine {
  /// Whether Glaze is "running" until the window asks to close it, to show the
  /// question.
  bool appOpen;

  /// Fails the run half-way, to show the error page.
  final bool fail;

  /// Version an earlier install had, or null for a fresh install.
  final String? previousVersion;

  /// Scales every pause; tests pass zero.
  final double pace;

  DemoEngine({
    this.appOpen = false,
    this.fail = false,
    this.previousVersion,
    this.pace = 1,
    super.channel,
  }) : super(_NoSystem());

  static const _files = [
    'Glaze.exe',
    'flutter_windows.dll',
    'data/app.so',
    'data/icudtl.dat',
    'data/flutter_assets/assets/fonts/InterVariable.ttf',
    'data/flutter_assets/assets/chat_webview/bridge.js',
    'WebView2Loader.dll',
    'flutter_inappwebview_windows_plugin.dll',
  ];

  Future<void> _pause(int ms) =>
      Future<void>.delayed(Duration(milliseconds: (ms * pace).round()));

  @override
  Future<Map<String, String>?> existingInstall() async =>
      previousVersion == null
      ? null
      : {'DisplayVersion': previousVersion!, 'GlazeDesktopShortcut': '1'};

  @override
  Future<InstallPaths> paths() async => InstallPaths(
    installDir:
        r'C:\Users\you\AppData\Local\Programs\com.glaze\'
        '${channel.appName}',
    dataDir:
        r'C:\Users\you\AppData\Roaming\'
        '${channel.dataFolder}',
    prefsDir: r'C:\Users\you\AppData\Roaming\com.glaze\Glaze',
    programsFolder:
        r'C:\Users\you\AppData\Roaming\Microsoft\Windows\Start Menu\Programs',
    desktopFolder: r'C:\Users\you\Desktop',
    appName: channel.appName,
  );

  @override
  Future<bool> canDeleteData() async => true;

  @override
  Future<void> closeApp(InstallPaths paths) async {
    appOpen = false;
    await system.kill(paths.exe);
  }

  Future<void> _waitForApp(SetupListener listener) async {
    if (appOpen) await listener.appRunning();
  }

  @override
  Future<void> install({
    required File payload,
    required File? package,
    required bool desktopShortcut,
    required SetupListener listener,
    String? importFrom,
  }) async {
    listener.onStep(SetupStep.close);
    listener.onProgress(0.02);
    await _pause(500);
    await _waitForApp(listener);
    listener.onStep(SetupStep.files);
    const ticks = 60;
    for (var i = 0; i < ticks; i++) {
      listener.onDetail(_files[i * _files.length ~/ ticks]);
      listener.onProgress(0.05 + 0.85 * (i + 1) / ticks);
      await _pause(45);
      if (fail && i == ticks ~/ 2) {
        throw const FileSystemException(
          'Access is denied',
          r'C:\Users\you\AppData\Local\Programs\com.glaze\Glaze\flutter_windows.dll',
          OSError('Access is denied', 5),
        );
      }
    }
    listener.onStep(SetupStep.shortcuts);
    listener.onDetail('');
    await _pause(500);
    listener.onProgress(0.95);
    listener.onStep(SetupStep.finish);
    await _pause(350);
    listener.onProgress(1);
  }

  @override
  Future<void> uninstall({
    required bool deleteData,
    required SetupListener listener,
  }) async {
    listener.onStep(SetupStep.close);
    await _pause(400);
    await _waitForApp(listener);
    listener.onStep(SetupStep.files);
    for (var i = 0; i < _files.length; i++) {
      listener.onDetail(_files[i]);
      listener.onProgress(0.05 + 0.6 * (i + 1) / _files.length);
      await _pause(150);
    }
    listener.onStep(SetupStep.shortcuts);
    listener.onDetail('');
    await _pause(400);
    listener.onProgress(0.75);
    if (deleteData) {
      listener.onStep(SetupStep.data);
      await _pause(500);
      listener.onProgress(0.95);
    }
    listener.onStep(SetupStep.finish);
    await _pause(300);
    listener.onProgress(1);
  }
}

/// Answers the controller's few direct calls; the engine methods that would
/// reach further are overridden above.
class _NoSystem implements SetupSystem {
  bool _running = true;

  @override
  String get localAppData => '';
  @override
  String get appData => '';
  @override
  Future<String> programsFolder() async => '';
  @override
  Future<String> desktopFolder() async => '';
  @override
  Future<Map<String, String>?> readKey(String key) async => null;
  @override
  Future<void> writeKey(String key, Map<String, Object> values) async {}
  @override
  Future<void> deleteKey(String key) async {}
  @override
  Future<bool> keyExists(String key) async => false;
  @override
  Future<void> createShortcut(String link, {required String target}) async {}
  // The demo engine's own flag decides; this only ever runs while it is set.
  @override
  Future<String?> shortcutTarget(String link) async => null;
  @override
  Future<bool> isRunning(String exe) async => _running;
  @override
  Future<void> kill(String exe) async => _running = false;
  @override
  Future<void> launch(String exe) async {}
  @override
  Future<void> deleteAfterExit(
    List<String> paths, {
    List<String> thenIfEmpty = const [],
  }) async {}
}
