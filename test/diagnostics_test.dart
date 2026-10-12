import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/diagnostics/crash_detector.dart';
import 'package:glaze_flutter/core/diagnostics/device_profile.dart';
import 'package:glaze_flutter/core/diagnostics/diagnostics_store.dart';
import 'package:glaze_flutter/core/diagnostics/log_redactor.dart';
import 'package:glaze_flutter/core/diagnostics/native_diagnostics.dart';
import 'package:glaze_flutter/core/diagnostics/session_tracker.dart';
import 'package:path/path.dart' as p;

AndroidExitInfo _exit(String reason) => AndroidExitInfo(
  reason: reason,
  description: null,
  timestamp: DateTime(2026, 10, 6, 12),
  importance: 100,
  status: 0,
  pssKb: 0,
  rssKb: 0,
  trace: null,
);

SessionRecord _session(SessionState state) => SessionRecord(
  logFile: 'sessions/2026-10-06_11-00-00.log',
  startedAt: DateTime(2026, 10, 6, 11),
  state: state,
);

void main() {
  group('LogRedactor', () {
    test('masks bearer tokens and provider keys', () {
      final out = LogRedactor.redact(
        'Authorization: Bearer sk-proj-abcdefghijklmnop1234 '
        'and key sk-ant-api03-ZZZZZZZZZZZZZZ',
      );
      expect(out, isNot(contains('abcdefghijklmnop1234')));
      expect(out, isNot(contains('ZZZZZZZZZZZZZZ')));
      expect(out, contains('Bearer sk-p***'));
    });

    test('masks key=value and JSON-style secrets', () {
      final out = LogRedactor.redact(
        'GET /v1/models?key=AIzaSyA1234567890abcdefghij "api_key": "hunter22secret"',
      );
      expect(out, isNot(contains('AIzaSyA1234567890abcdefghij')));
      expect(out, isNot(contains('hunter22secret')));
    });

    test('leaves ordinary lines alone', () {
      const line = '[tokenizer] count failed: RangeError (index): 3';
      expect(LogRedactor.redact(line), line);
    });
  });

  group('CrashDetector.classify', () {
    test('a run that ended in the background is not a crash', () {
      expect(
        CrashDetector.classify(
          previous: _session(SessionState.background),
          exit: _exit('SIGNALED'),
          hasJavaCrash: false,
        ),
        isNull,
      );
    });

    test('a run that ended on screen is an unclean exit', () {
      expect(
        CrashDetector.classify(
          previous: _session(SessionState.foreground),
          exit: null,
          hasJavaCrash: false,
        ),
        'UNCLEAN_EXIT',
      );
    });

    test('Android crash reasons win over the marker', () {
      expect(
        CrashDetector.classify(
          previous: _session(SessionState.background),
          exit: _exit('CRASH_NATIVE'),
          hasJavaCrash: false,
        ),
        'CRASH_NATIVE',
      );
    });

    test('an update or force stop while on screen is not a crash', () {
      for (final reason in ['PACKAGE_UPDATED', 'USER_REQUESTED', 'EXIT_SELF']) {
        expect(
          CrashDetector.classify(
            previous: _session(SessionState.foreground),
            exit: _exit(reason),
            hasJavaCrash: false,
          ),
          isNull,
          reason: reason,
        );
      }
    });

    test('an OOM kill on screen is reported as memory', () {
      expect(
        CrashDetector.classify(
          previous: _session(SessionState.foreground),
          exit: _exit('LOW_MEMORY'),
          hasJavaCrash: false,
        ),
        'LOW_MEMORY',
      );
    });

    test('a recorded JVM exception is always a crash', () {
      expect(
        CrashDetector.classify(previous: null, exit: null, hasJavaCrash: true),
        'CRASH',
      );
    });
  });

  test('report carries the kind, environment and log tail', () async {
    final report = await CrashDetector.buildReport(
      kind: 'ANR',
      previous: _session(SessionState.foreground),
      exit: _exit('ANR'),
      javaCrash: null,
      environment: 'Glaze 0.8.0 · nightly · release',
      previousLogTail: '12:00:00.000 I last line',
      now: DateTime(2026, 10, 6, 12, 1),
    );
    expect(report, contains('Kind:             ANR'));
    expect(report, contains('Glaze 0.8.0 · nightly · release'));
    expect(report, contains('--- Android exit info ---'));
    expect(report, endsWith('12:00:00.000 I last line\n'));
  });

  group('files', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('glaze_logs_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('session marker hands the previous run to the next one', () {
      final first = _session(SessionState.foreground);
      final (tracker, none) = SessionTracker.begin(
        logsRoot: dir.path,
        current: first,
      );
      expect(none, isNull);
      tracker.update(SessionState.background);

      final (_, previous) = SessionTracker.begin(
        logsRoot: dir.path,
        current: _session(SessionState.foreground),
      );
      expect(previous?.state, SessionState.background);
      expect(previous?.logFile, first.logFile);
    });

    test('a torn marker is ignored', () {
      File(p.join(dir.path, SessionTracker.markerName)).writeAsStringSync('{');
      final (_, previous) = SessionTracker.begin(
        logsRoot: dir.path,
        current: _session(SessionState.foreground),
      );
      expect(previous, isNull);
    });

    test('tail returns the last lines only', () async {
      final file = File(p.join(dir.path, 'a.log'))
        ..writeAsStringSync(
          [for (var i = 0; i < 1000; i++) 'line $i'].join('\n'),
        );
      final tail = await DiagnosticsStore.tail(file.path, maxLines: 3);
      expect(tail, 'line 997\nline 998\nline 999');
    });

    test('crash kind is read from the report header', () async {
      final file = File(p.join(dir.path, 'c.txt'))
        ..writeAsStringSync(
          'Glaze crash report\n===\nKind:             CRASH_NATIVE\n',
        );
      expect(await DiagnosticsStore.crashKind(file.path), 'CRASH_NATIVE');
    });
  });

  group('DeviceProfile', () {
    test('Android: model, build, SoC and memory', () {
      final profile = DeviceProfile.fromAndroid(
        {
          'manufacturer': 'samsung',
          'brand': 'samsung',
          'model': 'SM-S731B',
          'device': 'r12s',
          'release': '16',
          'sdk': 36,
          'securityPatch': '2026-09-01',
          'abis': 'arm64-v8a',
          'hardware': 's5e9945',
          'socManufacturer': 'Samsung',
          'socModel': 's5e9945',
          'cores': 10,
          'totalMem': 7 * 1024 * 1024 * 1024 + 512 * 1024 * 1024,
          'availMem': 2 * 1024 * 1024 * 1024,
          'lowMemThreshold': 216 * 1024 * 1024,
          'heapMb': 256,
          'lowRamDevice': false,
        },
        buildId: 'BP4A.251205.006.S731BXXS9BZH1',
        screen: '1080×2340 · 2.63x · 120 Hz',
      );
      expect(profile.lines, [
        'OS:     Android 16 (SDK 36) · BP4A.251205.006.S731BXXS9BZH1 · '
            'patch 2026-09-01',
        'Device: samsung SM-S731B · r12s',
        'CPU:    Samsung s5e9945 · 10 cores · arm64-v8a',
        'RAM:    7.5 GB · 2.0 GB free at launch · low-memory at 216 MB · '
            'app heap 256 MB',
        'Screen: 1080×2340 · 2.63x · 120 Hz',
      ]);
    });

    test('Android before 12 falls back to Build.HARDWARE', () {
      final profile = DeviceProfile.fromAndroid({
        'manufacturer': 'Xiaomi',
        'brand': 'Redmi',
        'model': 'M2003J15SC',
        'release': '11',
        'sdk': 30,
        'hardware': 'mt6768',
        'cores': 8,
        'abis': 'arm64-v8a,armeabi-v7a',
      }, buildId: '');
      expect(profile.os, 'Android 11 (SDK 30)');
      expect(profile.device, 'Xiaomi M2003J15SC · Redmi');
      expect(profile.cpu, 'mt6768 · 8 cores · arm64-v8a,armeabi-v7a');
      expect(profile.ram, isNull);
    });

    test('reg query output parses into keys and values', () {
      const out =
          '\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\r\n'
          '    ProductName    REG_SZ    Windows 10 Pro\r\n'
          '    DisplayVersion    REG_SZ    24H2\r\n'
          '    CurrentBuildNumber    REG_SZ    26100\r\n'
          '    UBR    REG_DWORD    0x1269\r\n';
      final keys = DeviceProfile.parseRegQuery(out);
      final nt = keys.values.single;
      expect(nt['ProductName'], 'Windows 10 Pro');
      expect(
        DeviceProfile.windowsName(nt),
        'Windows 11 Pro 24H2 (build 26100.4713)',
      );
    });

    test('Windows: CPU, GPUs and board fallback', () {
      final profile = DeviceProfile.fromWindows(
        nt: const {
          'ProductName': 'Windows 10 Home',
          'ReleaseId': '2009',
          'CurrentBuild': '19045',
        },
        bios: const {
          'SystemManufacturer': 'System manufacturer',
          'SystemProductName': 'System Product Name',
          'BaseBoardManufacturer': 'ASUSTeK COMPUTER INC.',
          'BaseBoardProduct': 'TUF GAMING B550-PLUS',
        },
        cpu: const {
          'ProcessorNameString': 'AMD Ryzen 7 5800X 8-Core Processor  ',
        },
        gpuClass: const {
          'k0000': {
            'DriverDesc': 'NVIDIA GeForce RTX 3070',
            'DriverVersion': '32.0.15.6094',
          },
          'Properties': {},
        },
        memory: (32 * 1024 * 1024 * 1024, 20 * 1024 * 1024 * 1024),
        fallbackOs: '"Windows 10 Home" 10.0 (Build 19045)',
        threads: 16,
        abi: 'windows_x64',
      );
      expect(profile.os, 'Windows 10 Home 2009 (build 19045)');
      expect(
        profile.device,
        'board: ASUSTeK COMPUTER INC. TUF GAMING B550-PLUS',
      );
      expect(
        profile.cpu,
        'AMD Ryzen 7 5800X 8-Core Processor · 16 threads · windows_x64',
      );
      expect(profile.ram, '32.0 GB · 20.0 GB free at launch');
      expect(profile.gpu, 'NVIDIA GeForce RTX 3070 (driver 32.0.15.6094)');
    });

    test('Linux: distro, kernel, laptop model and session', () {
      final profile = DeviceProfile.fromLinux(
        osRelease: 'NAME="Arch Linux"\nPRETTY_NAME="CachyOS"\nID=cachyos\n',
        cpuinfo:
            'processor\t: 0\nmodel name\t: AMD Ryzen 7 5800H\n'
            'processor\t: 1\nmodel name\t: AMD Ryzen 7 5800H\n',
        meminfo: 'MemTotal:       16303596 kB\nMemAvailable:    9000000 kB\n',
        vendor: 'LENOVO\n',
        product: '82JW\n',
        version: 'Legion 5 15ACH6H\n',
        boardVendor: 'LENOVO',
        board: 'LNVNB161216',
        gpus: const ['AMD (amdgpu)', 'NVIDIA (nvidia)'],
        kernel: '6.17.1-2-cachyos #1 SMP PREEMPT_DYNAMIC',
        threads: 16,
        abi: 'linux_x64',
        desktop: 'KDE',
        sessionType: 'wayland',
      );
      expect(profile.os, 'CachyOS · kernel 6.17.1-2-cachyos');
      expect(profile.device, 'LENOVO 82JW (Legion 5 15ACH6H)');
      expect(profile.cpu, 'AMD Ryzen 7 5800H · 16 threads · linux_x64');
      expect(profile.ram, '15.5 GB · 8.6 GB free at launch');
      expect(profile.gpu, 'AMD (amdgpu), NVIDIA (nvidia)');
      expect(profile.screen, 'KDE · wayland');
    });
  });

  test('file stamps round-trip', () {
    final t = DateTime(2026, 10, 6, 9, 5, 7);
    expect(DiagnosticsStore.parseStamp(DiagnosticsStore.stamp(t)), t);
    expect(DiagnosticsStore.parseStamp('${DiagnosticsStore.stamp(t)}_2'), t);
    expect(DiagnosticsStore.parseStamp('random.log'), isNull);
  });
}
