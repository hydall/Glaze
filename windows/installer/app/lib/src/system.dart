import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Everything the setup asks of Windows, behind one interface so the steps can
/// be run against a fake (`--demo`, tests).
///
/// The Windows side uses the tools every Windows 10 and 11 install has —
/// `reg.exe`, PowerShell, `cmd.exe` — rather than plugins, which keeps the
/// setup window a plain Flutter app.
abstract class SetupSystem {
  /// `%LOCALAPPDATA%`, `%APPDATA%`.
  String get localAppData;
  String get appData;

  /// The Start menu's Programs folder and the desktop, as the shell resolves
  /// them (the desktop may live in OneDrive).
  Future<String> programsFolder();
  Future<String> desktopFolder();

  /// Values of `HKCU\<key>`, or null when it does not exist.
  Future<Map<String, String>?> readKey(String key);
  Future<void> writeKey(String key, Map<String, Object> values);
  Future<void> deleteKey(String key);

  /// Whether `HKCU\<key>` or `HKLM\<key>` exists.
  Future<bool> keyExists(String key);

  Future<void> createShortcut(String link, {required String target});

  /// Whether a running program holds [exe] open — Windows locks a running
  /// executable against writing.
  Future<bool> isRunning(String exe);

  /// Ends every process started from [exe], and only those: another channel's
  /// Glaze, from another folder, keeps running.
  Future<void> kill(String exe);

  Future<void> launch(String exe);

  /// Deletes [paths] (folders, recursively) a few seconds after the setup has
  /// exited — the uninstaller cannot delete the folder it runs from — and
  /// then each of [thenIfEmpty] that is left empty.
  Future<void> deleteAfterExit(
    List<String> paths, {
    List<String> thenIfEmpty = const [],
  });
}

class WindowsSystem implements SetupSystem {
  @override
  String get localAppData => Platform.environment['LOCALAPPDATA']!;

  @override
  String get appData => Platform.environment['APPDATA']!;

  @override
  Future<String> programsFolder() => _folder('Programs');

  @override
  Future<String> desktopFolder() => _folder('Desktop');

  Future<String> _folder(String name) async {
    final out = await _powershell("[Environment]::GetFolderPath('$name')");
    return out.trim();
  }

  @override
  Future<Map<String, String>?> readKey(String key) async {
    // Not `reg query`: it prints in the console's code page, which mangles a
    // path under a Cyrillic user name.
    final out = await _powershell(
      r'$p = Get-ItemProperty -LiteralPath "HKCU:\$env:GLZ_KEY"'
      r' -ErrorAction SilentlyContinue;'
      r' if ($p) { $p | Select-Object * -ExcludeProperty PS* |'
      r' ConvertTo-Json -Compress }',
      env: {'GLZ_KEY': key},
    );
    return parseKeyJson(out);
  }

  @override
  Future<void> writeKey(String key, Map<String, Object> values) async {
    for (final MapEntry(key: name, :value) in values.entries) {
      await _run('reg', [
        'add',
        'HKCU\\$key',
        '/v',
        name,
        '/t',
        value is int ? 'REG_DWORD' : 'REG_SZ',
        '/d',
        '$value',
        '/f',
      ]);
    }
  }

  @override
  Future<void> deleteKey(String key) async {
    await Process.run('reg', ['delete', 'HKCU\\$key', '/f']);
  }

  @override
  Future<bool> keyExists(String key) async {
    for (final root in ['HKCU', 'HKLM']) {
      final r = await Process.run('reg', ['query', '$root\\$key']);
      if (r.exitCode == 0) return true;
    }
    return false;
  }

  @override
  Future<void> createShortcut(String link, {required String target}) async {
    await Directory(p.dirname(link)).create(recursive: true);
    // Paths go in through the environment: nothing to quote.
    await _powershell(
      r'$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:GLZ_LINK);'
      r' $s.TargetPath = $env:GLZ_TARGET;'
      r' $s.WorkingDirectory = Split-Path -Parent $env:GLZ_TARGET;'
      r' $s.IconLocation = "$env:GLZ_TARGET,0";'
      r' $s.Save()',
      env: {'GLZ_LINK': link, 'GLZ_TARGET': target},
    );
  }

  @override
  Future<bool> isRunning(String exe) async {
    if (!await File(exe).exists()) return false;
    try {
      final raf = await File(exe).open(mode: FileMode.append);
      await raf.close();
      return false;
    } on FileSystemException {
      return true;
    }
  }

  @override
  Future<void> kill(String exe) => _powershell(
    r'Get-Process | Where-Object { $_.Path -eq $env:GLZ_EXE } |'
    r' Stop-Process -Force',
    env: {'GLZ_EXE': exe},
  );

  @override
  Future<void> launch(String exe) async {
    await Process.start(
      exe,
      const [],
      workingDirectory: p.dirname(exe),
      mode: ProcessStartMode.detached,
    );
  }

  @override
  Future<void> deleteAfterExit(
    List<String> paths, {
    List<String> thenIfEmpty = const [],
  }) async {
    // A script rather than `cmd /c "…"`: cmd's own quoting rules and those
    // Dart applies to an argument do not agree. The paths reach it through
    // the environment, which carries any user name intact; a path written
    // into the file would go through the console code page. It retries for a
    // while — the launcher deletes its temp folder and exits a moment after
    // this window — then deletes itself.
    final env = <String, String>{
      for (var i = 0; i < paths.length; i++) 'GLZ_DEL_$i': paths[i],
      for (var i = 0; i < thenIfEmpty.length; i++)
        'GLZ_EMPTY_$i': thenIfEmpty[i],
    };
    final script = File(
      p.join(
        Directory.systemTemp.path,
        'glaze-cleanup-${DateTime.now().microsecondsSinceEpoch}.cmd',
      ),
    );
    await script.writeAsString(
      cleanupScript(paths.length, thenIfEmpty.length).join('\r\n'),
    );
    await Process.start(
      'cmd',
      ['/c', script.path],
      environment: env,
      // Not this window's folder: the launcher deletes that once the window
      // has exited, and a process standing in it would hold it.
      workingDirectory: Directory.systemTemp.path,
      mode: ProcessStartMode.detached,
    );
  }

  Future<String> _powershell(String command, {Map<String, String>? env}) =>
      _run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        // UTF-8 out, so a path under a Cyrillic user name comes back intact.
        '[Console]::OutputEncoding = [Text.Encoding]::UTF8; $command',
      ], env: env);

  Future<String> _run(
    String exe,
    List<String> args, {
    Map<String, String>? env,
  }) async {
    final r = await Process.run(
      exe,
      args,
      environment: env,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (r.exitCode != 0) {
      throw ProcessException(exe, args, '${r.stderr}'.trim(), r.exitCode);
    }
    return r.stdout as String;
  }
}

/// `Get-ItemProperty … | ConvertTo-Json` → value name to data, as text.
Map<String, String>? parseKeyJson(String output) {
  final text = output.trim();
  if (text.isEmpty) return null;
  final decoded = jsonDecode(text);
  if (decoded is! Map) return null;
  return {
    for (final MapEntry(:key, :value) in decoded.entries)
      if (value != null) '$key': '$value',
  };
}

/// The lines of the cleanup script for [paths] folders to delete
/// (`%GLZ_DEL_n%`) and [emptyDirs] to remove once empty (`%GLZ_EMPTY_n%`).
List<String> cleanupScript(int paths, int emptyDirs) => [
  '@echo off',
  'set /a tries=0',
  ':retry',
  'ping -n 2 127.0.0.1 >nul',
  for (var i = 0; i < paths; i++)
    'if exist "%GLZ_DEL_$i%" rmdir /s /q "%GLZ_DEL_$i%" 2>nul',
  for (var i = 0; i < paths; i++) 'if exist "%GLZ_DEL_$i%" goto again',
  'goto done',
  ':again',
  'set /a tries+=1',
  'if %tries% lss 15 goto retry',
  ':done',
  // rmdir without /s removes a folder only when it is empty.
  for (var i = 0; i < emptyDirs; i++) 'rmdir "%GLZ_EMPTY_$i%" 2>nul',
  '(goto) 2>nul & del "%~f0"',
];
