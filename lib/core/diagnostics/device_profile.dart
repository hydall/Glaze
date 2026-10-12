import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'native_diagnostics.dart';

/// The machine a log was written on: OS and its version, the device model,
/// CPU, memory, GPU and screen. Goes into every session header and crash
/// report, so a report read on another machine still says where it came from.
///
/// Every probe is best effort. A line that cannot be filled is left out; the
/// OS line always falls back to what `dart:io` reports.
class DeviceProfile {
  final String os;
  final String? device;
  final String? cpu;
  final String? ram;
  final String? gpu;

  /// Displays, plus the desktop and display server on Linux.
  final String? screen;

  const DeviceProfile({
    required this.os,
    this.device,
    this.cpu,
    this.ram,
    this.gpu,
    this.screen,
  });

  /// Report lines, labels padded to the column the rest of the header uses.
  List<String> get lines => [
    'OS:     $os',
    if (device != null) 'Device: $device',
    if (cpu != null) 'CPU:    $cpu',
    if (ram != null) 'RAM:    $ram',
    if (gpu != null) 'GPU:    $gpu',
    if (screen != null) 'Screen: $screen',
  ];

  static Future<DeviceProfile>? _collected;

  /// Probed once per process: "free at launch" means this launch.
  static Future<DeviceProfile> collect() => _collected ??= _collect().timeout(
    const Duration(seconds: 3),
    onTimeout: _fallback,
  );

  static Future<DeviceProfile> _collect() async {
    try {
      if (Platform.isAndroid) {
        final info = await NativeDiagnostics.deviceInfo();
        if (info == null) return _fallback();
        return fromAndroid(
          info,
          buildId: Platform.operatingSystemVersion,
          screen: _screen(),
        );
      }
      if (Platform.isWindows) return await _windows();
      if (Platform.isLinux) return await _linux();
      if (Platform.isMacOS) return await _macos();
    } catch (e) {
      debugPrint('DeviceProfile: probe failed — $e');
    }
    return _fallback();
  }

  static DeviceProfile _fallback() => DeviceProfile(
    os: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    cpu: _threads(),
    screen: _screen(),
  );

  // --- Android -------------------------------------------------------------

  @visibleForTesting
  static DeviceProfile fromAndroid(
    Map<Object?, Object?> info, {
    required String buildId,
    String? screen,
  }) {
    String? str(String key) => _clean(info[key]?.toString());
    int? integer(String key) => (info[key] as num?)?.toInt();

    final patch = str('securityPatch');
    final os = [
      'Android ${str('release') ?? '?'} (SDK ${integer('sdk') ?? '?'})',
      if (buildId.isNotEmpty) buildId,
      if (patch != null) 'patch $patch',
    ].join(' · ');

    final manufacturer = str('manufacturer');
    final brand = str('brand');
    final codename = str('device');
    final device = [
      [?manufacturer, ?str('model')].join(' '),
      if (brand != null && brand.toLowerCase() != manufacturer?.toLowerCase())
        brand,
      ?codename,
    ].where((part) => part.isNotEmpty).join(' · ');

    final socModel = str('socModel');
    final soc = socModel != null
        ? [?str('socManufacturer'), socModel].join(' ')
        : str('hardware');
    final cores = integer('cores');
    final cpu = [
      ?soc,
      if (cores != null) '$cores cores',
      ?str('abis'),
    ].join(' · ');

    final total = integer('totalMem');
    final avail = integer('availMem');
    final threshold = integer('lowMemThreshold');
    final heap = integer('heapMb');
    final ram = total == null
        ? null
        : [
            formatBytes(total),
            if (avail != null) '${formatBytes(avail)} free at launch',
            if (threshold != null) 'low-memory at ${formatBytes(threshold)}',
            if (heap != null) 'app heap $heap MB',
            if (info['lowRamDevice'] == true) 'low-RAM device',
          ].join(' · ');

    return DeviceProfile(
      os: os,
      device: device.isEmpty ? null : device,
      cpu: cpu.isEmpty ? null : cpu,
      ram: ram,
      screen: screen,
    );
  }

  // --- Windows -------------------------------------------------------------

  static const _ntKey = r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion';
  static const _biosKey = r'HKLM\HARDWARE\DESCRIPTION\System\BIOS';
  static const _cpuKey = r'HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0';
  static const _gpuClassKey =
      r'HKLM\SYSTEM\CurrentControlSet\Control\Class'
      r'\{4d36e968-e325-11ce-bfc1-08002be10318}';

  static Future<DeviceProfile> _windows() async {
    final results = await Future.wait([
      _reg([_ntKey]),
      _reg([_biosKey]),
      _reg([_cpuKey, '/v', 'ProcessorNameString']),
      _reg([_gpuClassKey, '/s']),
    ]);
    return fromWindows(
      nt: _firstKey(results[0]),
      bios: _firstKey(results[1]),
      cpu: _firstKey(results[2]),
      gpuClass: results[3],
      memory: _windowsMemory(),
      fallbackOs: Platform.operatingSystemVersion,
      threads: Platform.numberOfProcessors,
      abi: Abi.current().toString(),
      screen: _screen(),
    );
  }

  @visibleForTesting
  static DeviceProfile fromWindows({
    required Map<String, String> nt,
    required Map<String, String> bios,
    required Map<String, String> cpu,
    required Map<String, Map<String, String>> gpuClass,
    required (int, int)? memory,
    required String fallbackOs,
    required int threads,
    required String abi,
    String? screen,
  }) {
    return DeviceProfile(
      os: windowsName(nt) ?? fallbackOs,
      device: _hardwareName(
        vendor: bios['SystemManufacturer'],
        product: bios['SystemProductName'],
        version: bios['SystemVersion'],
        boardVendor: bios['BaseBoardManufacturer'],
        board: bios['BaseBoardProduct'],
      ),
      cpu: [
        ?_clean(cpu['ProcessorNameString']),
        '$threads threads',
        abi,
      ].join(' · '),
      ram: memory == null
          ? null
          : '${formatBytes(memory.$1)} · '
                '${formatBytes(memory.$2)} free at launch',
      gpu: _join({
        for (final values in gpuClass.values)
          if (_clean(values['DriverDesc']) case final name?)
            switch (_clean(values['DriverVersion'])) {
              final version? => '$name (driver $version)',
              null => name,
            },
      }),
      screen: screen,
    );
  }

  /// `ProductName` still says "Windows 10" on Windows 11; the build number is
  /// what tells them apart.
  @visibleForTesting
  static String? windowsName(Map<String, String> nt) {
    var product = _clean(nt['ProductName']);
    if (product == null) return null;
    final build = _clean(nt['CurrentBuildNumber'] ?? nt['CurrentBuild']);
    if ((int.tryParse(build ?? '') ?? 0) >= 22000) {
      product = product.replaceFirst('Windows 10', 'Windows 11');
    }
    final ubr = _regInt(nt['UBR']);
    return [
      product,
      ?_clean(nt['DisplayVersion'] ?? nt['ReleaseId']),
      if (build != null) '(build $build${ubr != null ? '.$ubr' : ''})',
    ].join(' ');
  }

  static Future<Map<String, Map<String, String>>> _reg(
    List<String> args,
  ) async {
    final result = await Process.run('reg', ['query', ...args]);
    if (result.exitCode != 0) return const {};
    return parseRegQuery(result.stdout as String);
  }

  static Map<String, String> _firstKey(Map<String, Map<String, String>> keys) =>
      keys.isEmpty ? const {} : keys.values.first;

  /// `reg query` output: a line per key, then its values indented as
  /// `Name    REG_TYPE    Data`.
  @visibleForTesting
  static Map<String, Map<String, String>> parseRegQuery(String output) {
    final keys = <String, Map<String, String>>{};
    Map<String, String>? current;
    final value = RegExp(r'^\s+(.+?)\s+REG_[A-Z_]+\s*(.*)$');
    for (final line in output.split(RegExp(r'\r?\n'))) {
      if (line.startsWith('HKEY_')) {
        current = keys.putIfAbsent(line.trim(), () => {});
        continue;
      }
      final match = value.firstMatch(line);
      if (match != null && current != null) {
        current[match.group(1)!] = match.group(2)!.trim();
      }
    }
    return keys;
  }

  static int? _regInt(String? raw) {
    if (raw == null) return null;
    return raw.startsWith('0x')
        ? int.tryParse(raw.substring(2), radix: 16)
        : int.tryParse(raw);
  }

  /// (total, available) physical memory, from `GlobalMemoryStatusEx`.
  static (int, int)? _windowsMemory() {
    try {
      final status = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<
            Int32 Function(Pointer<_MemoryStatusEx>),
            int Function(Pointer<_MemoryStatusEx>)
          >('GlobalMemoryStatusEx');
      final buffer = calloc<_MemoryStatusEx>();
      try {
        buffer.ref.length = sizeOf<_MemoryStatusEx>();
        if (status(buffer) == 0) return null;
        return (buffer.ref.totalPhys, buffer.ref.availPhys);
      } finally {
        calloc.free(buffer);
      }
    } catch (_) {
      return null;
    }
  }

  // --- Linux ---------------------------------------------------------------

  static Future<DeviceProfile> _linux() async {
    Future<String?> read(String path) async {
      try {
        return await File(path).readAsString();
      } catch (_) {
        return null;
      }
    }

    const dmi = '/sys/class/dmi/id';
    final files = await Future.wait<String?>([
      read(
        '/etc/os-release',
      ).then((v) async => v ?? await read('/usr/lib/os-release')),
      read('/proc/cpuinfo'),
      read('/proc/meminfo'),
      read('$dmi/sys_vendor'),
      read('$dmi/product_name'),
      read('$dmi/product_version'),
      read('$dmi/board_vendor'),
      read('$dmi/board_name'),
      read('/proc/sys/kernel/osrelease'),
    ]);
    final env = Platform.environment;
    return fromLinux(
      osRelease: files[0],
      cpuinfo: files[1],
      meminfo: files[2],
      vendor: files[3],
      product: files[4],
      version: files[5],
      boardVendor: files[6],
      board: files[7],
      gpus: await _linuxGpus(),
      kernel: _clean(files[8]) ?? Platform.operatingSystemVersion,
      threads: Platform.numberOfProcessors,
      abi: Abi.current().toString(),
      desktop: env['XDG_CURRENT_DESKTOP'],
      sessionType: env['XDG_SESSION_TYPE'],
      screen: _screen(),
    );
  }

  @visibleForTesting
  static DeviceProfile fromLinux({
    required String? osRelease,
    required String? cpuinfo,
    required String? meminfo,
    required String? vendor,
    required String? product,
    required String? version,
    required String? boardVendor,
    required String? board,
    required List<String> gpus,
    required String kernel,
    required int threads,
    required String abi,
    String? desktop,
    String? sessionType,
    String? screen,
  }) {
    final release = _keyValues(osRelease ?? '', '=');
    final distro =
        _clean(release['PRETTY_NAME']) ??
        _clean([?release['NAME'], ?release['VERSION_ID']].join(' ')) ??
        'Linux';

    final cpu = _keyValues(cpuinfo ?? '', ':');
    final cpuName = _clean(
      cpu['model name'] ?? cpu['Hardware'] ?? cpu['Model'] ?? cpu['cpu model'],
    );

    final mem = _keyValues(meminfo ?? '', ':');
    int? kb(String key) =>
        int.tryParse((mem[key] ?? '').split(' ').first.trim());
    final total = kb('MemTotal');
    final available = kb('MemAvailable');

    final screenLine = [
      ?screen,
      ?_clean(desktop),
      ?_clean(sessionType),
    ].join(' · ');

    return DeviceProfile(
      os: '$distro · kernel ${kernel.replaceFirst('Linux ', '').split(' ').first}',
      device: _hardwareName(
        vendor: vendor,
        product: product,
        version: version,
        boardVendor: boardVendor,
        board: board,
      ),
      cpu: [?cpuName, '$threads threads', abi].join(' · '),
      ram: total == null
          ? null
          : [
              formatBytes(total * 1024),
              if (available != null)
                '${formatBytes(available * 1024)} free at launch',
            ].join(' · '),
      gpu: _join(gpus),
      screen: screenLine.isEmpty ? null : screenLine,
    );
  }

  /// DRM cards as "vendor (kernel driver)": no `lspci` needed, and the driver
  /// is what a rendering bug report actually turns on.
  static Future<List<String>> _linuxGpus() async {
    final gpus = <String>{};
    try {
      final cards = Directory('/sys/class/drm').listSync().where(
        (entry) => RegExp(r'^card\d+$').hasMatch(p.basename(entry.path)),
      );
      for (final card in cards) {
        final dir = '${card.path}/device';
        final vendorId = (await File('$dir/vendor').readAsString()).trim();
        String? driver;
        try {
          driver = Link('$dir/driver').targetSync().split('/').last;
        } catch (_) {}
        gpus.add(
          [linuxGpuVendor(vendorId), if (driver != null) '($driver)'].join(' '),
        );
      }
    } catch (_) {}
    return gpus.toList();
  }

  @visibleForTesting
  static String linuxGpuVendor(String pciId) => switch (pciId.toLowerCase()) {
    '0x10de' => 'NVIDIA',
    '0x1002' => 'AMD',
    '0x8086' => 'Intel',
    '0x1af4' => 'Virtio',
    '0x15ad' => 'VMware',
    _ => 'vendor $pciId',
  };

  // --- macOS ---------------------------------------------------------------

  static Future<DeviceProfile> _macos() async {
    final result = await Process.run('/usr/sbin/sysctl', [
      'hw.model',
      'hw.memsize',
      'machdep.cpu.brand_string',
    ]);
    final sysctl = _keyValues(result.stdout as String, ':');
    final memsize = int.tryParse(sysctl['hw.memsize'] ?? '');
    return DeviceProfile(
      // "Version 15.1 (Build 24B83)"
      os: 'macOS ${Platform.operatingSystemVersion.replaceFirst('Version ', '')}',
      device: _clean(sysctl['hw.model']),
      cpu: [
        ?_clean(sysctl['machdep.cpu.brand_string']),
        '${Platform.numberOfProcessors} threads',
        Abi.current().toString(),
      ].join(' · '),
      ram: memsize == null ? null : formatBytes(memsize),
      screen: _screen(),
    );
  }

  // --- Shared --------------------------------------------------------------

  static String _threads() =>
      '${Platform.numberOfProcessors} threads · ${Abi.current()}';

  /// Every display the engine knows of: physical pixels, scale, refresh rate.
  static String? _screen() {
    try {
      return _join([
        for (final d in PlatformDispatcher.instance.displays)
          '${d.size.width.round()}×${d.size.height.round()} · '
              '${d.devicePixelRatio.toStringAsFixed(2)}x · '
              '${d.refreshRate.round()} Hz',
      ], separator: '; ');
    } catch (_) {
      return null;
    }
  }

  /// "Lenovo 82JW (Legion 5 15ACH6H)"; the board when the vendor left the
  /// system fields at their placeholder, as self-built desktops do.
  static String? _hardwareName({
    String? vendor,
    String? product,
    String? version,
    String? boardVendor,
    String? board,
  }) {
    final v = _real(vendor);
    final p = _real(product);
    if (p != null) {
      final extra = _real(version);
      final hasLetters = extra != null && RegExp('[A-Za-z]').hasMatch(extra);
      return [?v, p, if (hasLetters && extra != p) '($extra)'].join(' ');
    }
    final b = _real(board);
    if (b != null) return 'board: ${[?_real(boardVendor), b].join(' ')}';
    return v;
  }

  static const _placeholders = [
    'o.e.m',
    'default string',
    'system product name',
    'system manufacturer',
    'system version',
    'not applicable',
    'not specified',
    'none',
    'unknown',
  ];

  /// [_clean] that also drops the stock firmware placeholders.
  static String? _real(String? value) {
    final v = _clean(value);
    if (v == null) return null;
    final lower = v.toLowerCase();
    return _placeholders.any(lower.contains) ? null : v;
  }

  static String? _clean(String? value) {
    final v = value?.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (v == null || v.isEmpty || v == 'unknown') return null;
    // os-release quotes its values.
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      return _clean(v.substring(1, v.length - 1));
    }
    return v;
  }

  static String? _join(Iterable<String> parts, {String separator = ', '}) {
    final list = parts.where((part) => part.isNotEmpty).toList();
    return list.isEmpty ? null : list.join(separator);
  }

  /// First occurrence wins: `/proc/cpuinfo` repeats every key per core.
  static Map<String, String> _keyValues(String text, String separator) {
    final map = <String, String>{};
    for (final line in text.split('\n')) {
      final i = line.indexOf(separator);
      if (i <= 0) continue;
      map.putIfAbsent(line.substring(0, i).trim(), () {
        return line.substring(i + separator.length).trim();
      });
    }
    return map;
  }

  @visibleForTesting
  static String formatBytes(int bytes) {
    const gb = 1024 * 1024 * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    return '${(bytes / (1024 * 1024)).round()} MB';
  }
}

final class _MemoryStatusEx extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int memoryLoad;
  @Uint64()
  external int totalPhys;
  @Uint64()
  external int availPhys;
  @Uint64()
  external int totalPageFile;
  @Uint64()
  external int availPageFile;
  @Uint64()
  external int totalVirtual;
  @Uint64()
  external int availVirtual;
  @Uint64()
  external int availExtendedVirtual;
}
