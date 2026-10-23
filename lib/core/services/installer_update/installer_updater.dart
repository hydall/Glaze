import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'installer_asset.dart';

/// Why an update could not be installed. Each has its own message in the UI.
enum InstallerUpdateError {
  /// Network failure, a non-200 answer, or the checksum file was unreadable.
  download,

  /// The file arrived with the wrong size or SHA-256 — it is deleted, never
  /// run.
  verification,

  /// Windows refused to start the installer.
  launch,
}

class InstallerUpdateException implements Exception {
  final InstallerUpdateError error;
  final String detail;

  const InstallerUpdateException(this.error, this.detail);

  @override
  String toString() => 'InstallerUpdateException(${error.name}): $detail';
}

/// Downloads the Windows installer from a GitHub Release, checks it, and hands
/// over to it.
///
/// Only ever fetches an [InstallerAsset] — URLs under the release's own
/// download folder on github.com (redirects to GitHub's asset CDN included) —
/// and only ever runs a file whose size and SHA-256 match what the GitHub API
/// reported for it.
class InstallerUpdater {
  InstallerUpdater({
    required this.owner,
    required this.repo,
    Dio? dio,
    this.downloadDir,
    String? executablePath,
    Future<void> Function(String exe, List<String> args)? startProcess,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 60),
               headers: {'User-Agent': 'Glaze-Updater'},
               validateStatus: (_) => true,
             ),
           ),
       _executablePath = executablePath ?? Platform.resolvedExecutable,
       _startProcess = startProcess ?? _startDetached;

  final String owner;
  final String repo;
  final Dio _dio;

  /// Where the installer is saved; a `Glaze-update` folder in the system
  /// temp directory by default.
  final Directory? downloadDir;
  final String _executablePath;
  final Future<void> Function(String exe, List<String> args) _startProcess;

  /// Whether this copy of Glaze was put here by the installer — its
  /// uninstaller sits next to the exe. A copy unpacked from the zip is not,
  /// and a silent install would land in the installer's folder instead and
  /// leave this one as it is, so such copies run the installer visibly.
  bool get isInstalledBySetup =>
      File(p.join(p.dirname(_executablePath), 'unins000.exe')).existsSync();

  /// Fetches [asset] into a temporary folder and verifies it. Returns the
  /// checked file; anything that fails the check is deleted first.
  Future<File> download(
    InstallerAsset asset, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (!InstallerAsset.isTrustedDownloadUrl(asset.url, owner, repo)) {
      throw const InstallerUpdateException(
        InstallerUpdateError.verification,
        'installer URL is outside the release',
      );
    }
    final expectedSha = asset.sha256 ?? await _fetchChecksum(asset);

    final dir =
        downloadDir ??
        Directory(p.join(Directory.systemTemp.path, 'Glaze-update'));
    await dir.create(recursive: true);
    // The asset name came from the API; only its last segment is used, so it
    // cannot point the file anywhere outside [dir].
    final file = File(p.join(dir.path, p.basename(asset.url.path)));
    final partial = File('${file.path}.part');

    try {
      final res = await _dio.downloadUri(
        asset.url,
        partial.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) =>
            onProgress?.call(received, asset.size),
        options: Options(followRedirects: true, maxRedirects: 5),
      );
      if (res.statusCode != 200) {
        throw InstallerUpdateException(
          InstallerUpdateError.download,
          'HTTP ${res.statusCode}',
        );
      }
      if (res.realUri.scheme != 'https') {
        throw const InstallerUpdateException(
          InstallerUpdateError.verification,
          'redirected off HTTPS',
        );
      }
    } on DioException catch (e) {
      await _deleteQuietly(partial);
      if (CancelToken.isCancel(e)) rethrow;
      throw InstallerUpdateException(InstallerUpdateError.download, '$e');
    } on InstallerUpdateException {
      await _deleteQuietly(partial);
      rethrow;
    }

    await verify(partial, size: asset.size, sha256: expectedSha);
    if (await file.exists()) await file.delete();
    return partial.rename(file.path);
  }

  /// Throws [InstallerUpdateError.verification] (and deletes [file]) unless it
  /// is exactly [size] bytes with the given SHA-256.
  @visibleForTesting
  static Future<void> verify(
    File file, {
    required int size,
    required String sha256,
  }) async {
    final actualSize = await file.length();
    if (actualSize != size) {
      await _deleteQuietly(file);
      throw InstallerUpdateException(
        InstallerUpdateError.verification,
        'size $actualSize, expected $size',
      );
    }
    final digest = await sha256Of(file);
    if (digest != sha256) {
      await _deleteQuietly(file);
      throw InstallerUpdateException(
        InstallerUpdateError.verification,
        'sha256 $digest, expected $sha256',
      );
    }
  }

  @visibleForTesting
  static Future<String> sha256Of(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  /// Starts the verified installer. With [silent] — an installed copy — it
  /// runs without a wizard, closes Glaze if it is still up, and starts it
  /// again when done; the caller quits right after. Otherwise the wizard
  /// shows, so a zip copy's user sees where Glaze is going.
  Future<void> launch(File installer, {required bool silent}) async {
    final args = silent
        ? const [
            '/VERYSILENT',
            '/SUPPRESSMSGBOXES',
            '/CLOSEAPPLICATIONS',
            '/NORESTART',
            '/RELAUNCH=1',
          ]
        : const <String>[];
    try {
      await _startProcess(installer.path, args);
    } on ProcessException catch (e) {
      throw InstallerUpdateException(InstallerUpdateError.launch, '$e');
    }
  }

  Future<String> _fetchChecksum(InstallerAsset asset) async {
    final url = asset.checksumUrl;
    if (url == null || !InstallerAsset.isTrustedDownloadUrl(url, owner, repo)) {
      throw const InstallerUpdateException(
        InstallerUpdateError.verification,
        'no checksum for the installer',
      );
    }
    try {
      final res = await _dio.getUri<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final sha = res.statusCode == 200 && res.data != null
          ? InstallerAsset.parseChecksumFile(res.data!)
          : null;
      if (sha == null) {
        throw const InstallerUpdateException(
          InstallerUpdateError.download,
          'checksum file unreadable',
        );
      }
      return sha;
    } on DioException catch (e) {
      throw InstallerUpdateException(InstallerUpdateError.download, '$e');
    }
  }

  static Future<void> _startDetached(String exe, List<String> args) async {
    await Process.start(exe, args, mode: ProcessStartMode.detached);
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A leftover in the temp folder is harmless; it is overwritten next time.
    }
  }
}
