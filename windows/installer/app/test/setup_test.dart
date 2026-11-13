import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_setup/src/args.dart';
import 'package:glaze_setup/src/config.dart';
import 'package:glaze_setup/src/controller.dart';
import 'package:glaze_setup/src/demo.dart';
import 'package:glaze_setup/src/engine.dart';
import 'package:glaze_setup/src/package.dart';
import 'package:glaze_setup/src/system.dart';
import 'package:glaze_setup/src/zip.dart';
import 'package:path/path.dart' as p;

/// A zip as .NET's ZipFile writes it: local headers, central directory, end
/// record. [deflate] compresses every entry.
Uint8List makeZip(Map<String, List<int>> files, {bool deflate = true}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  for (final MapEntry(key: name, value: data) in files.entries) {
    final nameBytes = utf8.encode(name);
    final body = deflate ? ZLibCodec(raw: true).encode(data) : data;
    final crc = _crc32(data);
    final offset = out.length;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0x800, Endian.little)
      ..setUint16(8, deflate ? 8 : 0, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, body.length, Endian.little)
      ..setUint32(22, data.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(nameBytes)
      ..add(body);
    final entry = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0x800, Endian.little)
      ..setUint16(10, deflate ? 8 : 0, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, body.length, Endian.little)
      ..setUint32(24, data.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(entry.buffer.asUint8List())
      ..add(nameBytes);
    count++;
  }
  final dirOffset = out.length;
  final dir = central.takeBytes();
  out.add(dir);
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint16(10, count, Endian.little)
    ..setUint32(12, dir.length, Endian.little)
    ..setUint32(16, dirOffset, Endian.little);
  out.add(end.buffer.asUint8List());
  return out.takeBytes();
}

int _crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
  }
  return c ^ 0xFFFFFFFF;
}

/// Records what the engine asks of Windows; the files it writes are real,
/// under a temp folder.
class FakeSystem implements SetupSystem {
  final String root;
  final keys = <String, Map<String, String>>{};
  final shortcuts = <String>[];

  /// Every shortcut's target, ours and those that were there before.
  final linkTargets = <String, String>{};
  final killed = <String>[];
  final deferred = <String>[];
  final thenIfEmpty = <String>[];
  bool running = false;
  bool legacy = false;

  FakeSystem(this.root);

  @override
  String get localAppData => p.join(root, 'Local');
  @override
  String get appData => p.join(root, 'Roaming');
  @override
  Future<String> programsFolder() async => p.join(root, 'Programs');
  @override
  Future<String> desktopFolder() async => p.join(root, 'Desktop');
  @override
  Future<Map<String, String>?> readKey(String key) async => keys[key];
  @override
  Future<void> writeKey(String key, Map<String, Object> values) async =>
      keys[key] = {for (final e in values.entries) e.key: '${e.value}'};
  @override
  Future<void> deleteKey(String key) async => keys.remove(key);
  @override
  Future<bool> keyExists(String key) async =>
      legacy && key == legacyElectronUninstallKey;
  @override
  Future<void> createShortcut(String link, {required String target}) async {
    shortcuts.add(link);
    linkTargets[link] = target;
    await File(link).create(recursive: true);
  }

  @override
  Future<String?> shortcutTarget(String link) async => linkTargets[link];

  @override
  Future<bool> isRunning(String exe) async => running;
  @override
  Future<void> kill(String exe) async {
    killed.add(exe);
    running = false;
  }

  @override
  Future<void> launch(String exe) async {}
  @override
  Future<void> deleteAfterExit(
    List<String> paths, {
    List<String> thenIfEmpty = const [],
  }) async {
    deferred.addAll(paths);
    this.thenIfEmpty.addAll(thenIfEmpty);
  }
}

class RecordingListener implements SetupListener {
  final steps = <SetupStep>[];
  final progress = <double>[];
  int appRunningCalls = 0;
  void Function()? onAppRunning;

  @override
  void onStep(SetupStep step) => steps.add(step);
  @override
  void onProgress(double value) => progress.add(value);
  @override
  void onDetail(String detail) {}
  @override
  Future<void> appRunning() async {
    appRunningCalls++;
    onAppRunning?.call();
  }
}

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('glzsetup'));
  tearDown(() async => tmp.delete(recursive: true));

  group('zip', () {
    test('reads stored and deflated entries, UTF-8 names included', () async {
      for (final deflate in [true, false]) {
        final file = File(p.join(tmp.path, 'a$deflate.zip'));
        final big = List<int>.generate(700000, (i) => (i * 31) % 251);
        await file.writeAsBytes(
          makeZip({
            'Glaze.exe': big,
            'data/flutter_assets/ёлка.txt': utf8.encode('привет'),
          }, deflate: deflate),
        );
        final zip = ZipReader(file);
        final entries = await zip.entries();
        expect(entries.map((e) => e.name), [
          'Glaze.exe',
          'data/flutter_assets/ёлка.txt',
        ]);
        var reported = 0;
        final out = File(p.join(tmp.path, 'out$deflate', 'Glaze.exe'));
        await zip.extract(entries[0], out, onBytes: (n) => reported += n);
        expect(await out.readAsBytes(), big);
        expect(reported, big.length);
        final text = File(p.join(tmp.path, 'out$deflate', 'ёлка.txt'));
        await zip.extract(entries[1], text);
        expect(await text.readAsString(), 'привет');
      }
    });

    test('a damaged entry is refused and leaves no file', () async {
      final bytes = makeZip({'a.bin': List.filled(5000, 7)}, deflate: false);
      bytes[40] ^= 0xFF; // inside the stored data
      final file = File(p.join(tmp.path, 'bad.zip'))..writeAsBytesSync(bytes);
      final zip = ZipReader(file);
      final out = File(p.join(tmp.path, 'x', 'a.bin'));
      await expectLater(
        zip.extract((await zip.entries()).single, out),
        throwsFormatException,
      );
      expect(out.existsSync(), isFalse);
      expect(File('${out.path}.glzpart').existsSync(), isFalse);
    });

    test('a path never leaves the install folder', () {
      final root = p.join(tmp.path, 'app');
      expect(safeTarget(root, 'data/x'), p.join(root, 'data', 'x'));
      expect(safeTarget(root, '../evil.exe'), isNull);
      expect(safeTarget(root, 'data/../../evil.exe'), isNull);
    });
  });

  group('package', () {
    test(
      'the footer round-trips, and the uninstaller drops the build',
      () async {
        final head = List<int>.filled(1000, 1);
        final ui = List<int>.filled(300, 2);
        final payload = List<int>.filled(5000, 3);
        final footer = PackageFooter(
          method: 1,
          uiOffset: head.length,
          uiSize: ui.length,
          uiRawSize: 900,
          payloadOffset: head.length + ui.length,
          payloadSize: payload.length,
        );
        final setup = File(p.join(tmp.path, 'GlazeSetup.exe'))
          ..writeAsBytesSync([...head, ...ui, ...payload, ...footer.toBytes()]);

        final read = (await PackageFooter.read(setup))!;
        expect(read.payloadSize, payload.length);
        expect(read.uiRawSize, 900);

        final uninstaller = File(p.join(tmp.path, 'u', 'GlazeSetup.exe'));
        await writeUninstaller(setup, uninstaller);
        final bytes = await uninstaller.readAsBytes();
        expect(bytes.length, head.length + ui.length + PackageFooter.size);
        final copy = (await PackageFooter.read(uninstaller))!;
        expect(copy.payloadSize, 0);
        expect(copy.uiOffset, head.length);
        expect(bytes.sublist(0, 1300), [...head, ...ui]);
      },
    );

    test('a file without the footer is not a setup', () async {
      final f = File(p.join(tmp.path, 'x'))
        ..writeAsBytesSync(List.filled(100, 0));
      expect(await PackageFooter.read(f), isNull);
    });
  });

  group('engine', () {
    late FakeSystem system;
    late SetupEngine engine;
    late File payload;
    late File package;

    setUp(() async {
      system = FakeSystem(tmp.path);
      engine = SetupEngine(system, channel: const Channel('nightly'));
      payload = File(p.join(tmp.path, 'glaze.zip'))
        ..writeAsBytesSync(
          makeZip({
            'Glaze.exe': utf8.encode('exe v2'),
            'data/app.so': utf8.encode('aot'),
            // A Release folder the build was run from: never shipped.
            'Glaze.exe.WebView2/EBWebView/Cookies': utf8.encode('dev cookies'),
          }),
        );
      package = File(p.join(tmp.path, 'GlazeSetup.exe'))
        ..writeAsBytesSync([
          ...List.filled(64, 9),
          ...PackageFooter(
            method: 0,
            uiOffset: 10,
            uiSize: 20,
            uiRawSize: 20,
            payloadOffset: 30,
            payloadSize: 34,
          ).toBytes(),
        ]);
    });

    Future<InstallPaths> install({bool desktop = true}) async {
      await engine.install(
        payload: payload,
        package: package,
        desktopShortcut: desktop,
        listener: RecordingListener(),
      );
      return engine.paths();
    }

    test(
      'installs, registers, and keeps the user\'s profile on update',
      () async {
        final paths = await install();
        expect(
          paths.installDir,
          p.join(tmp.path, 'Local', 'Programs', 'com.glaze', 'Glaze Nightly'),
        );
        expect(File(paths.exe).readAsStringSync(), 'exe v2');
        expect(File(paths.uninstaller).existsSync(), isTrue);
        expect(Directory(paths.webViewProfile).existsSync(), isFalse);
        expect(system.shortcuts, [paths.startMenuLink, paths.desktopLink]);
        final key = (await engine.existingInstall())!;
        expect(key['DisplayName'], 'Glaze Nightly');
        expect(key['InstallLocation'], paths.installDir);
        expect(key['UninstallString'], contains('--uninstall'));

        // The user's own profile and an asset a newer build dropped.
        File(p.join(paths.webViewProfile, 'Cookies'))
          ..createSync(recursive: true)
          ..writeAsStringSync('mine');
        File(
          p.join(paths.installDir, 'data', 'old.dat'),
        ).writeAsStringSync('stale');
        system.shortcuts.clear();
        await install(desktop: false);
        expect(
          File(p.join(paths.webViewProfile, 'Cookies')).readAsStringSync(),
          'mine',
        );
        expect(
          File(p.join(paths.installDir, 'data', 'old.dat')).existsSync(),
          isFalse,
        );
        expect(File(paths.desktopLink).existsSync(), isFalse);
        expect((await engine.existingInstall())!['GlazeDesktopShortcut'], '0');
      },
    );

    test('a running Glaze is waited for before files change', () async {
      await install();
      system.running = true;
      final listener = RecordingListener()
        ..onAppRunning = () => system.running = false;
      await engine.install(
        payload: payload,
        package: null,
        desktopShortcut: true,
        listener: listener,
      );
      expect(listener.appRunningCalls, 1);
    });

    test(
      'uninstall keeps data unless asked, and never another channel\'s',
      () async {
        final paths = await install();
        final data = Directory(paths.dataDir)..createSync(recursive: true);
        final prefs = Directory(paths.prefsDir)..createSync(recursive: true);
        Directory(
          p.join(paths.webViewProfile, 'x'),
        ).createSync(recursive: true);

        await engine.uninstall(
          deleteData: false,
          listener: RecordingListener(),
        );
        expect(File(paths.exe).existsSync(), isFalse);
        expect(
          Directory(p.join(paths.installDir, 'data')).existsSync(),
          isFalse,
        );
        expect(Directory(paths.webViewProfile).existsSync(), isTrue);
        expect(data.existsSync(), isTrue);
        expect(prefs.existsSync(), isTrue);
        expect(await engine.existingInstall(), isNull);
        expect(File(paths.startMenuLink).existsSync(), isFalse);
        // The running uninstaller's own folder goes after exit.
        expect(system.deferred, [paths.uninstallDir]);
        expect(system.thenIfEmpty, contains(paths.installDir));

        // Stable's data folder exists: shared prefs stay with it.
        await install();
        final stable = Directory(p.join(system.appData, 'Glaze'))
          ..createSync(recursive: true);
        await engine.uninstall(deleteData: true, listener: RecordingListener());
        expect(data.existsSync(), isFalse);
        expect(Directory(paths.webViewProfile).existsSync(), isFalse);
        expect(prefs.existsSync(), isTrue);
        expect(stable.existsSync(), isTrue);
      },
    );

    test(
      'stable keeps its data while the old Electron app is installed',
      () async {
        system.legacy = true;
        final stable = SetupEngine(system, channel: const Channel('stable'));
        expect(await stable.canDeleteData(), isFalse);
        expect(await engine.canDeleteData(), isTrue);
        system.legacy = false;
        expect(await stable.canDeleteData(), isTrue);
      },
    );

    test(
      'a build without Glaze.exe is refused before anything changes',
      () async {
        payload.writeAsBytesSync(makeZip({'readme.txt': utf8.encode('x')}));
        await expectLater(install(), throwsFormatException);
        expect(Directory(p.join(tmp.path, 'Local')).existsSync(), isFalse);
      },
    );
  });

  group('an older Glaze on the machine', () {
    late FakeSystem system;
    late SetupEngine engine;
    late File payload;

    /// Everything an older Glaze leaves behind, with something in it.
    late Map<String, String> before;

    String file(String path, String content) {
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
      return path;
    }

    Map<String, String> snapshot(Iterable<String> roots) => {
      for (final root in roots)
        if (Directory(root).existsSync())
          for (final f in Directory(root).listSync(recursive: true))
            if (f is File) f.path: f.readAsStringSync(),
    };

    late List<String> roots;

    setUp(() {
      system = FakeSystem(tmp.path);
      engine = SetupEngine(system, channel: const Channel('stable'));
      payload = File(p.join(tmp.path, 'glaze.zip'))
        ..writeAsBytesSync(makeZip({'Glaze.exe': utf8.encode('new')}));
      final roaming = p.join(tmp.path, 'Roaming');
      final local = p.join(tmp.path, 'Local');
      // A portable copy, unpacked by hand, with its WebView2 profile.
      final portable = p.join(tmp.path, 'Downloads', 'Glaze');
      // The legacy Electron app: its folder, its data in the same place as
      // stable's, its shortcuts with the same name as ours.
      final electron = p.join(local, 'Programs', 'glaze');
      file(p.join(portable, 'Glaze.exe'), 'old portable');
      file(p.join(portable, 'data', 'app.so'), 'old aot');
      file(
        p.join(portable, 'Glaze.exe.WebView2', 'EBWebView', 'Cookies'),
        'logins',
      );
      file(p.join(electron, 'Glaze.exe'), 'electron');
      file(p.join(roaming, 'Glaze', 'glaze.db'), 'chats');
      file(p.join(roaming, 'Glaze-nightly', 'glaze.db'), 'nightly chats');
      file(
        p.join(roaming, 'com.glaze', 'Glaze', 'shared_preferences.json'),
        '{}',
      );
      for (final folder in ['Programs', 'Desktop']) {
        final link = file(
          p.join(tmp.path, folder, 'Glaze.lnk'),
          'electron link',
        );
        system.linkTargets[link] = p.join(electron, 'Glaze.exe');
      }
      roots = [
        portable,
        electron,
        p.join(roaming, 'Glaze'),
        p.join(roaming, 'Glaze-nightly'),
        p.join(roaming, 'com.glaze'),
      ];
      before = snapshot(roots);
      system.legacy = true;
    });

    test('install, update and uninstall leave all of it as it was', () async {
      Future<void> install({bool desktop = true}) => engine.install(
        payload: payload,
        package: null,
        desktopShortcut: desktop,
        listener: RecordingListener(),
      );
      await install();
      await install(desktop: false);
      await install();
      final paths = await engine.paths();
      expect(File(paths.exe).readAsStringSync(), 'new');

      // The old shortcuts still start the old app; ours sit beside them.
      final ours = p.join(tmp.path, 'Desktop', 'Glaze (2).lnk');
      for (final folder in ['Programs', 'Desktop']) {
        expect(
          system.linkTargets[p.join(tmp.path, folder, 'Glaze.lnk')],
          endsWith(p.join('glaze', 'Glaze.exe')),
        );
        expect(
          File(p.join(tmp.path, folder, 'Glaze.lnk')).readAsStringSync(),
          'electron link',
        );
      }
      expect(system.linkTargets[ours], paths.exe);
      // Reinstalling reuses its own shortcut rather than adding a (3).
      expect(
        File(p.join(tmp.path, 'Desktop', 'Glaze (3).lnk')).existsSync(),
        isFalse,
      );

      // Uninstall with "delete my data" ticked: the legacy app is installed,
      // so stable's data stays anyway.
      await engine.uninstall(deleteData: true, listener: RecordingListener());
      expect(File(ours).existsSync(), isFalse);
      expect(
        File(p.join(tmp.path, 'Desktop', 'Glaze.lnk')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(tmp.path, 'Programs', 'Glaze.lnk')).existsSync(),
        isTrue,
      );
      expect(snapshot(roots), before);
    });

    test('a portable copy\'s logins are copied over, never moved', () async {
      final portable = p.join(tmp.path, 'Downloads', 'Glaze');
      await engine.install(
        payload: payload,
        package: null,
        desktopShortcut: false,
        listener: RecordingListener(),
        importFrom: portable,
      );
      final paths = await engine.paths();
      expect(
        File(
          p.join(paths.webViewProfile, 'EBWebView', 'Cookies'),
        ).readAsStringSync(),
        'logins',
      );
      expect(snapshot(roots), before);

      // A profile the install already has is never replaced.
      File(
        p.join(paths.webViewProfile, 'EBWebView', 'Cookies'),
      ).writeAsStringSync('newer');
      await engine.install(
        payload: payload,
        package: null,
        desktopShortcut: false,
        listener: RecordingListener(),
        importFrom: portable,
      );
      expect(
        File(
          p.join(paths.webViewProfile, 'EBWebView', 'Cookies'),
        ).readAsStringSync(),
        'newer',
      );
    });
  });

  test('arguments', () {
    final update = SetupArgs.parse([
      '--update',
      '--package',
      r'C:\a b\GlazeSetup.exe',
      '--payload',
      r'C:\t\glaze.zip',
    ]);
    expect(update.mode, SetupMode.update);
    expect(update.package, r'C:\a b\GlazeSetup.exe');
    expect(update.payload, r'C:\t\glaze.zip');
    expect(
      SetupArgs.parse(['--import-from', r'D:\Glaze']).importFrom,
      r'D:\Glaze',
    );
    expect(SetupArgs.parse(['--uninstall', '--silent']).silent, isTrue);
    // Only an uninstall may run unseen.
    expect(SetupArgs.parse(['--silent']).silent, isFalse);
    expect(SetupArgs.parse([]).mode, SetupMode.install);
  });

  test('channels', () {
    expect(const Channel('stable').dataFolder, 'Glaze');
    expect(const Channel('stable').appName, 'Glaze');
    expect(const Channel('nightly').dataFolder, 'Glaze-nightly');
    expect(const Channel('nightly').appName, 'Glaze Nightly');
    expect(
      const Channel('stable').uninstallKey,
      isNot(const Channel('nightly').uninstallKey),
    );
  });

  test('registry values come back through JSON, Cyrillic intact', () {
    expect(
      parseKeyJson(
        '{"DisplayVersion":"0.9.1","InstallLocation":"C:\\\\Users\\\\Иван","NoModify":1}',
      ),
      {
        'DisplayVersion': '0.9.1',
        'InstallLocation': r'C:\Users\Иван',
        'NoModify': '1',
      },
    );
    expect(parseKeyJson(''), isNull);
  });

  test('the cleanup script reads its paths from the environment', () {
    final script = cleanupScript(1, 2).join('\n');
    expect(script, contains('rmdir /s /q "%GLZ_DEL_0%"'));
    expect(script, contains('rmdir "%GLZ_EMPTY_1%"'));
    expect(script, contains('del "%~f0"'));
  });

  group('controller', () {
    test('an install runs every step to the end', () async {
      final c = SetupController(
        args: const SetupArgs(demo: true),
        engine: DemoEngine(pace: 0),
      );
      await c.load();
      expect(c.phase, SetupPhase.welcome);
      await c.start();
      expect(c.phase, SetupPhase.done);
      expect(c.progress, 1);
    });

    test(
      'an update starts on its own and closes a Glaze that lingers',
      () async {
        final engine = DemoEngine(pace: 0, appOpen: true);
        final c = SetupController(
          args: const SetupArgs(demo: true, mode: SetupMode.update),
          engine: engine,
          updateGrace: Duration.zero,
        );
        await c.load();
        expect(c.phase, SetupPhase.done);
        expect(engine.appOpen, isFalse);
      },
    );

    test('a failure is shown, and can be tried again', () async {
      final c = SetupController(
        args: const SetupArgs(demo: true),
        engine: DemoEngine(pace: 0, fail: true),
      );
      await c.load();
      await c.start();
      expect(c.phase, SetupPhase.failed);
      expect(c.error, isA<FileSystemException>());
    });

    test('without a build the install says so', () async {
      final c = SetupController(
        args: const SetupArgs(),
        engine: DemoEngine(pace: 0),
      );
      await c.load();
      await c.start();
      expect(c.missingPayload, isTrue);
    });

    test('a silent uninstall needs nobody', () async {
      final c = SetupController(
        args: SetupArgs.parse(['--uninstall', '--silent', '--demo']),
        engine: DemoEngine(pace: 0),
      );
      await c.load();
      expect(c.phase, SetupPhase.done);
    });
  });
}
