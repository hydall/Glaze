import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/installer_update/installer_asset.dart';
import 'package:glaze_flutter/core/services/installer_update/installer_updater.dart';
import 'package:glaze_flutter/core/services/update_check_service.dart';

const _owner = 'hydall';
const _repo = 'Glaze';
const _base = 'https://github.com/hydall/Glaze/releases/download/v0.9.1';

final _payload = Uint8List.fromList(utf8.encode('pretend this is setup.exe'));
final _payloadSha = sha256.convert(_payload).toString();

Map<String, dynamic> _asset(
  String name, {
  int? size,
  String? digest,
  String? url,
}) => {
  'name': name,
  'size': size ?? 100,
  'digest': digest,
  'browser_download_url': url ?? '$_base/$name',
};

/// Trimmed from a real `/repos/hydall/Glaze/releases/latest` answer.
Map<String, dynamic> _release({
  String tag = 'v0.9.1',
  List<Map<String, dynamic>>? assets,
}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/hydall/Glaze/releases/tag/$tag',
  'published_at': '2026-10-25T12:00:00Z',
  'body': '## Changes\n\n* Windows installer',
  'assets':
      assets ??
      [
        _asset('$tag.apk', digest: 'sha256:${'1' * 64}'),
        _asset('$tag-windows.zip', digest: 'sha256:${'2' * 64}'),
        _asset(
          '$tag-windows-setup.exe',
          size: 31000000,
          digest: 'sha256:${'A' * 64}',
        ),
        _asset('$tag-windows-setup.exe.sha256', size: 90),
      ],
};

InstallerAsset? _pick(Map<String, dynamic> release) =>
    InstallerAsset.fromRelease(release, owner: _owner, repo: _repo);

void main() {
  group('releaseResult (stable channel)', () {
    test('a newer tag is an update and carries the installer', () {
      final result = UpdateCheckService.releaseResult(
        _release(),
        installedVersion: '0.9.0',
      );
      expect(result.status, UpdateStatus.available);
      final info = result.info!;
      expect(info.label, 'v0.9.1');
      expect(info.notes, ['Windows installer']);
      expect(info.installer?.name, 'v0.9.1-windows-setup.exe');
      expect(info.installer?.size, 31000000);
      expect(info.installer?.sha256, 'a' * 64);
    });

    test('0.10.0 is newer than 0.9.0', () {
      final result = UpdateCheckService.releaseResult(
        _release(tag: 'v0.10.0'),
        installedVersion: '0.9.0',
      );
      expect(result.status, UpdateStatus.available);
    });

    test('the installed version or older is up to date', () {
      for (final tag in ['v0.9.0', 'v0.8.2', 'v0.9.0-rc1']) {
        expect(
          UpdateCheckService.releaseResult(
            _release(tag: tag),
            installedVersion: '0.9.0',
          ).status,
          UpdateStatus.upToDate,
          reason: tag,
        );
      }
    });

    test('an unreadable tag or version cannot tell', () {
      expect(
        UpdateCheckService.releaseResult(
          _release(tag: 'nightly'),
          installedVersion: '0.9.0',
        ).status,
        UpdateStatus.unknown,
      );
      expect(
        UpdateCheckService.releaseResult({}, installedVersion: '0.9.0').status,
        UpdateStatus.unknown,
      );
    });

    test('a release without an installer is still offered, without one', () {
      final result = UpdateCheckService.releaseResult(
        _release(assets: [_asset('v0.9.1-windows.zip')]),
        installedVersion: '0.9.0',
      );
      expect(result.status, UpdateStatus.available);
      expect(result.info!.installer, isNull);
    });
  });

  group('InstallerAsset.fromRelease', () {
    test('falls back to the .sha256 sidecar when GitHub gave no digest', () {
      final asset = _pick(
        _release(
          assets: [
            _asset('v0.9.1-windows-setup.exe'),
            _asset('v0.9.1-windows-setup.exe.sha256'),
          ],
        ),
      )!;
      expect(asset.sha256, isNull);
      expect(
        asset.checksumUrl.toString(),
        '$_base/v0.9.1-windows-setup.exe.sha256',
      );
    });

    test('without digest or sidecar there is nothing to verify against', () {
      expect(
        _pick(_release(assets: [_asset('v0.9.1-windows-setup.exe')])),
        isNull,
      );
    });

    test('rejects download URLs outside the release', () {
      for (final url in [
        'http://github.com/hydall/Glaze/releases/download/v0.9.1/x-windows-setup.exe',
        'https://evil.example/hydall/Glaze/releases/download/v0.9.1/x-windows-setup.exe',
        'https://github.com/someone/Glaze/releases/download/v0.9.1/x-windows-setup.exe',
        'https://github.com/hydall/Glaze/releases/download/../../../someone/x-windows-setup.exe',
        'https://github.com:8443/hydall/Glaze/releases/download/v1/x-windows-setup.exe',
        'https://user@github.com/hydall/Glaze/releases/download/v1/x-windows-setup.exe',
      ]) {
        final release = _release(
          assets: [
            _asset(
              'x-windows-setup.exe',
              url: url,
              digest: 'sha256:${'a' * 64}',
            ),
          ],
        );
        expect(_pick(release), isNull, reason: url);
      }
    });

    test('ignores a malformed size or digest', () {
      expect(
        _pick(
          _release(
            assets: [
              _asset(
                'v-windows-setup.exe',
                size: 0,
                digest: 'sha256:${'a' * 64}',
              ),
            ],
          ),
        ),
        isNull,
      );
      expect(
        _pick(
          _release(
            assets: [_asset('v-windows-setup.exe', digest: 'sha256:abc')],
          ),
        ),
        isNull,
      );
    });

    test('no assets list at all', () {
      expect(_pick({'tag_name': 'v1'}), isNull);
    });
  });

  group('checksum parsing', () {
    test('digest and sha256sum lines', () {
      expect(InstallerAsset.parseDigest('sha256:${'F' * 64}'), 'f' * 64);
      expect(InstallerAsset.parseDigest('md5:${'f' * 32}'), isNull);
      expect(InstallerAsset.parseDigest(null), isNull);
      expect(
        InstallerAsset.parseChecksumFile(
          '${'b' * 64}  v0.9.1-windows-setup.exe\n',
        ),
        'b' * 64,
      );
      expect(InstallerAsset.parseChecksumFile('not a hash'), isNull);
    });
  });

  group('InstallerUpdater', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('glaze_updater_test');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    InstallerUpdater updater(
      Map<String, List<int>> files, {
      List<List<String>>? started,
    }) {
      final dio = Dio(BaseOptions(validateStatus: (_) => true));
      dio.httpClientAdapter = _FileAdapter(files);
      return InstallerUpdater(
        owner: _owner,
        repo: _repo,
        dio: dio,
        downloadDir: tmp,
        executablePath: '${tmp.path}${Platform.pathSeparator}Glaze.exe',
        startProcess: (exe, args) async => started?.add([exe, ...args]),
      );
    }

    InstallerAsset asset({int? size, String? sha, bool sidecar = false}) =>
        InstallerAsset(
          name: 'v0.9.1-windows-setup.exe',
          url: Uri.parse('$_base/v0.9.1-windows-setup.exe'),
          size: size ?? _payload.length,
          sha256: sidecar ? null : (sha ?? _payloadSha),
          checksumUrl: Uri.parse('$_base/v0.9.1-windows-setup.exe.sha256'),
        );

    test('downloads and verifies against the API digest', () async {
      final file = await updater({
        '/hydall/Glaze/releases/download/v0.9.1/v0.9.1-windows-setup.exe':
            _payload,
      }).download(asset());
      expect(await file.readAsBytes(), _payload);
      expect(file.path, endsWith('v0.9.1-windows-setup.exe'));
    });

    test('verifies against the sidecar when there is no digest', () async {
      final file = await updater({
        '/hydall/Glaze/releases/download/v0.9.1/v0.9.1-windows-setup.exe':
            _payload,
        '/hydall/Glaze/releases/download/v0.9.1/v0.9.1-windows-setup.exe.sha256':
            utf8.encode('$_payloadSha  v0.9.1-windows-setup.exe\n'),
      }).download(asset(sidecar: true));
      expect(await file.exists(), isTrue);
    });

    test('a wrong hash is deleted and never returned', () async {
      final u = updater({
        '/hydall/Glaze/releases/download/v0.9.1/v0.9.1-windows-setup.exe':
            _payload,
      });
      await expectLater(
        u.download(asset(sha: '0' * 64)),
        throwsA(
          isA<InstallerUpdateException>().having(
            (e) => e.error,
            'error',
            InstallerUpdateError.verification,
          ),
        ),
      );
      expect(tmp.listSync(), isEmpty);
    });

    test('a wrong size is rejected', () async {
      await expectLater(
        updater({
          '/hydall/Glaze/releases/download/v0.9.1/v0.9.1-windows-setup.exe':
              _payload,
        }).download(asset(size: _payload.length + 1)),
        throwsA(isA<InstallerUpdateException>()),
      );
      expect(tmp.listSync(), isEmpty);
    });

    test('a 404 is a download error', () async {
      await expectLater(
        updater({}).download(asset()),
        throwsA(
          isA<InstallerUpdateException>().having(
            (e) => e.error,
            'error',
            InstallerUpdateError.download,
          ),
        ),
      );
    });

    test('refuses an asset pointing outside the release', () async {
      final bad = InstallerAsset(
        name: 'x-windows-setup.exe',
        url: Uri.parse('https://evil.example/x-windows-setup.exe'),
        size: _payload.length,
        sha256: _payloadSha,
      );
      await expectLater(
        updater({'/x-windows-setup.exe': _payload}).download(bad),
        throwsA(isA<InstallerUpdateException>()),
      );
    });

    test('an installed copy starts the setup as an update', () async {
      final started = <List<String>>[];
      final file = File('${tmp.path}${Platform.pathSeparator}setup.exe');
      await updater({}, started: started).launch(file, silent: true);
      await updater({}, started: started).launch(file, silent: false);
      expect(started.first, [file.path, '--update']);
      // A zip copy hands over its folder, for its WebView2 profile.
      expect(started.last, [file.path, '--import-from', tmp.path]);
    });

    test(
      'a zip copy runs the wizard, an installed copy runs silently',
      () async {
        final u = updater({});
        expect(u.isInstalledBySetup, isFalse);
        await File(
          '${tmp.path}${Platform.pathSeparator}uninstall'
          '${Platform.pathSeparator}GlazeSetup.exe',
        ).create(recursive: true);
        expect(u.isInstalledBySetup, isTrue);
      },
    );
  });

  group('nightly: the rolling pre-release', () {
    const installed = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const head = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

    UpdateCheckService service(Map<String, Object> routes) {
      final dio = Dio(
        BaseOptions(
          baseUrl: 'https://api.github.com',
          validateStatus: (_) => true,
        ),
      );
      dio.httpClientAdapter = _JsonAdapter(routes);
      return UpdateCheckService(dio: dio, installedCommit: installed);
    }

    final nightly = <String, Object>{
      'tag_name': 'nightly-build',
      'target_commitish': head,
      'prerelease': true,
      'created_at': '2026-10-29T12:00:00Z',
      'html_url': 'https://github.com/$_owner/$_repo/releases/tag/nightly-build',
      'assets': [
        {
          'name': 'Glaze-nightly-windows-setup.exe',
          'size': 41000000,
          'digest': 'sha256:${'c' * 64}',
          'browser_download_url':
              'https://github.com/$_owner/$_repo/releases/download/nightly-build/'
              'Glaze-nightly-windows-setup.exe',
        },
      ],
    };
    final ahead = {
      'status': 'ahead',
      'commits': [
        {
          'parents': [<String, Object>{}],
          'commit': {'message': 'feat: one'},
        },
        {
          'parents': [<String, Object>{}],
          'commit': {'message': 'fix: two\n\nbody'},
        },
      ],
    };

    test('a newer build is offered with its setup and commits', () async {
      final result = await service({
        '/repos/$_owner/$_repo/releases/tags/nightly-build': nightly,
        '/repos/$_owner/$_repo/compare/$installed...$head': ahead,
      }).checkNightlyRelease();
      expect(result.status, UpdateStatus.available);
      final info = result.info!;
      expect(info.source, UpdateSource.nightlyRelease);
      expect(info.dismissId, head);
      expect(info.label, 'nightly · bbbbbbb');
      expect(info.notes, ['fix: two', 'feat: one']);
      expect(info.installer?.name, 'Glaze-nightly-windows-setup.exe');
    });

    test('the same commit, or an older release, is up to date', () async {
      final same = await service({
        '/repos/$_owner/$_repo/releases/tags/nightly-build': {
          ...nightly,
          'target_commitish': installed,
        },
      }).checkNightlyRelease();
      expect(same.status, UpdateStatus.upToDate);
      final behind = await service({
        '/repos/$_owner/$_repo/releases/tags/nightly-build': nightly,
        '/repos/$_owner/$_repo/compare/$installed...$head': {
          'status': 'behind',
          'commits': <Object>[],
        },
      }).checkNightlyRelease();
      expect(behind.status, UpdateStatus.upToDate);
    });

    test('no release yet falls back to the Actions run', () async {
      final result = await service({
        '/repos/$_owner/$_repo/actions/workflows/build-branch.yml/runs': {
          'workflow_runs': [
            {'head_sha': head, 'run_number': 42},
          ],
        },
        '/repos/$_owner/$_repo/compare/$installed...$head': ahead,
      }).checkNightlyRelease();
      expect(result.info?.source, UpdateSource.ciBuild);
      expect(result.info?.label, '#42');
      expect(result.info?.installer, isNull);
    });
  });
}

/// Answers API paths with JSON; anything else is a 404.
class _JsonAdapter implements HttpClientAdapter {
  _JsonAdapter(this.routes);

  final Map<String, Object> routes;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = routes[options.uri.path];
    // GitHub answers a 404 with a JSON body too.
    return ResponseBody.fromString(
      jsonEncode(body ?? {'message': 'Not Found'}),
      body == null ? 404 : 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Serves [files] by URL path; anything else is a 404.
class _FileAdapter implements HttpClientAdapter {
  _FileAdapter(this.files);

  final Map<String, List<int>> files;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = files[options.uri.path];
    if (body == null) return ResponseBody.fromString('not found', 404);
    return ResponseBody.fromBytes(
      body,
      200,
      headers: {
        Headers.contentLengthHeader: ['${body.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
