import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'package.dart';
import 'system.dart';
import 'zip.dart';

/// The steps a run goes through, in the order the window lists them.
enum SetupStep { close, files, shortcuts, data, finish }

/// What a run reports while it goes. Implemented by the window's controller.
abstract class SetupListener {
  void onStep(SetupStep step);

  /// Overall progress, 0 to 1.
  void onProgress(double value);

  /// The file being written or removed, for the faint line under the ring.
  void onDetail(String detail);

  /// Glaze is running from the folder about to change. Completes once it is
  /// gone: on its own, or because the reader asked for it to be closed — the
  /// listener decides, and calls [SetupEngine.closeApp] for the latter.
  Future<void> appRunning();
}

/// Where one channel of Glaze lives on this machine.
class InstallPaths {
  final String installDir;
  final String dataDir;
  final String prefsDir;
  final String programsFolder;
  final String desktopFolder;
  final String appName;

  const InstallPaths({
    required this.installDir,
    required this.dataDir,
    required this.prefsDir,
    required this.programsFolder,
    required this.desktopFolder,
    required this.appName,
  });

  String get exe => p.join(installDir, 'Glaze.exe');
  String get uninstallDir => p.join(installDir, 'uninstall');
  String get uninstaller => p.join(uninstallDir, 'GlazeSetup.exe');

  /// The WebView2 profile — catalog logins and cookies — which WebView2 keeps
  /// next to the executable. User data, though it sits in the install folder.
  String get webViewProfile => p.join(installDir, 'Glaze.exe.WebView2');
  String get startMenuLink => p.join(programsFolder, '$appName.lnk');
  String get desktopLink => p.join(desktopFolder, '$appName.lnk');
}

/// The install, update and uninstall themselves.
///
/// Install and update are one path: an update is an install over an existing
/// one, into the folder it already has. User data is never touched by either:
/// it lives outside the install folder, and the WebView2 profile inside it is
/// left in place.
class SetupEngine {
  final SetupSystem system;
  final Channel channel;

  SetupEngine(this.system, {this.channel = Channel.current});

  String get _uninstallKey =>
      r'Software\Microsoft\Windows\CurrentVersion\Uninstall\'
      '${channel.uninstallKey}';

  /// The Apps entry of an earlier install of this channel, if any.
  Future<Map<String, String>?> existingInstall() =>
      system.readKey(_uninstallKey);

  Future<InstallPaths> paths() async {
    final existing = await existingInstall();
    final previous = existing?['InstallLocation'];
    return InstallPaths(
      // An earlier install keeps its folder.
      installDir: previous != null && p.isAbsolute(previous)
          ? previous
          : p.join(
              system.localAppData,
              'Programs',
              // Not Programs\Glaze: the legacy Electron app sits there, and
              // its uninstaller deletes that whole folder.
              'com.glaze',
              channel.appName,
            ),
      dataDir: p.join(system.appData, channel.dataFolder),
      prefsDir: p.join(system.appData, 'com.glaze', 'Glaze'),
      programsFolder: await system.programsFolder(),
      desktopFolder: await system.desktopFolder(),
      appName: channel.appName,
    );
  }

  /// Whether data may be deleted on uninstall. Not on stable while the legacy
  /// Electron app is installed: it keeps its data in the same folder.
  Future<bool> canDeleteData() async =>
      !(channel.isStable && await system.keyExists(legacyElectronUninstallKey));

  Future<void> closeApp(InstallPaths paths) => system.kill(paths.exe);

  Future<void> install({
    required File payload,
    required File? package,
    required bool desktopShortcut,
    required SetupListener listener,
  }) async {
    final paths = await this.paths();
    final zip = ZipReader(payload);

    listener.onStep(SetupStep.close);
    listener.onProgress(0.02);
    final entries = [
      for (final e in await zip.entries())
        if (!e.isDirectory && !_isUserData(e.name)) e,
    ];
    if (!entries.any((e) => e.name == 'Glaze.exe')) {
      throw const FormatException('the setup file carries no Glaze.exe');
    }
    if (await system.isRunning(paths.exe)) await listener.appRunning();

    listener.onStep(SetupStep.files);
    // data\ is pure build output — flutter_assets, the AOT snapshot, ICU
    // data. Clearing it keeps assets a newer version dropped from lingering.
    final data = Directory(p.join(paths.installDir, 'data'));
    if (await data.exists()) await data.delete(recursive: true);

    final total = entries.fold<int>(0, (sum, e) => sum + e.size);
    var done = 0;
    for (final entry in entries) {
      final target = safeTarget(paths.installDir, entry.name);
      if (target == null) {
        throw FormatException('${entry.name} points outside the folder');
      }
      listener.onDetail(entry.name);
      await zip.extract(
        entry,
        File(target),
        onBytes: (bytes) {
          done += bytes;
          listener.onProgress(0.05 + 0.85 * done / (total == 0 ? 1 : total));
        },
      );
    }
    if (package != null) {
      listener.onDetail('uninstall/GlazeSetup.exe');
      await writeUninstaller(package, File(paths.uninstaller));
    }

    listener.onStep(SetupStep.shortcuts);
    listener.onDetail('');
    await system.createShortcut(paths.startMenuLink, target: paths.exe);
    final desktop = File(paths.desktopLink);
    if (desktopShortcut) {
      await system.createShortcut(paths.desktopLink, target: paths.exe);
    } else if (await desktop.exists()) {
      await desktop.delete();
    }
    listener.onProgress(0.95);

    await system.writeKey(_uninstallKey, {
      'DisplayName': channel.appName,
      'DisplayVersion': setupVersion,
      'Publisher': 'Glaze',
      'DisplayIcon': paths.exe,
      'InstallLocation': paths.installDir,
      'UninstallString': '"${paths.uninstaller}" --uninstall',
      'QuietUninstallString': '"${paths.uninstaller}" --uninstall --silent',
      'URLInfoAbout': 'https://github.com/hydall/Glaze',
      'HelpLink': 'https://github.com/hydall/Glaze/issues',
      'NoModify': 1,
      'NoRepair': 1,
      'EstimatedSize': (total ~/ 1024) + 10240,
      'GlazeChannel': channel.id,
      'GlazeCommit': setupCommit,
      'GlazeDesktopShortcut': desktopShortcut ? 1 : 0,
    });

    listener.onStep(SetupStep.finish);
    listener.onProgress(1);
  }

  Future<void> uninstall({
    required bool deleteData,
    required SetupListener listener,
  }) async {
    final paths = await this.paths();
    deleteData = deleteData && await canDeleteData();

    listener.onStep(SetupStep.close);
    listener.onProgress(0.02);
    if (await system.isRunning(paths.exe)) await listener.appRunning();

    listener.onStep(SetupStep.files);
    final root = Directory(paths.installDir);
    if (await root.exists()) {
      final keep = {
        paths.uninstallDir,
        if (!deleteData) paths.webViewProfile,
      }.map(p.normalize).toSet();
      final items = [
        await for (final e in root.list())
          if (!keep.contains(p.normalize(e.path))) e,
      ];
      for (var i = 0; i < items.length; i++) {
        listener.onDetail(p.basename(items[i].path));
        await items[i].delete(recursive: true);
        listener.onProgress(0.05 + 0.6 * (i + 1) / items.length);
      }
    }

    listener.onStep(SetupStep.shortcuts);
    listener.onDetail('');
    for (final link in [paths.startMenuLink, paths.desktopLink]) {
      final file = File(link);
      if (await file.exists()) await file.delete();
    }
    await system.deleteKey(_uninstallKey);
    listener.onProgress(0.75);

    if (deleteData) {
      listener.onStep(SetupStep.data);
      for (final dir in [paths.dataDir, paths.webViewProfile]) {
        listener.onDetail(dir);
        final d = Directory(dir);
        if (await d.exists()) await d.delete(recursive: true);
      }
      final others = [
        for (final folder in knownDataFolders)
          if (folder != channel.dataFolder)
            Directory(p.join(system.appData, folder)),
      ];
      var otherLeft = false;
      for (final d in others) {
        if (await d.exists()) otherLeft = true;
      }
      if (!otherLeft) {
        final prefs = Directory(paths.prefsDir);
        if (await prefs.exists()) await prefs.delete(recursive: true);
      }
      listener.onProgress(0.95);
    }

    listener.onStep(SetupStep.finish);
    listener.onDetail('');
    // The uninstaller runs from uninstall\, so that and the folders around it
    // go once this window has closed. The install folder goes only when it is
    // empty by then: a kept WebView2 profile stays where Glaze will find it.
    await system.deleteAfterExit(
      [paths.uninstallDir],
      thenIfEmpty: [paths.installDir, p.dirname(paths.installDir)],
    );
    listener.onProgress(1);
  }

  /// The WebView2 profile of a Release folder the app was run from: shipping
  /// it would overwrite the user's own on every update.
  static bool _isUserData(String name) =>
      name.startsWith('Glaze.exe.WebView2/') || name.startsWith('uninstall/');
}
