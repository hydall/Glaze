import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../../core/constants/build_channel.dart';
import '../../cloud_adapter.dart';
import '../../sync_models.dart';
import 'dropbox_auth.dart';

class DropboxAdapter implements CloudAdapter {
  static const _apiBase = 'https://api.dropboxapi.com/2';
  static const _contentBase = 'https://content.dropboxapi.com/2';
  static const _deleteBatchPolls = 30;

  // Dropbox hands the app its own App folder as the API root, so the Glaze root
  // itself collapses to '' — that is why paths are stripped rather than used
  // as-is. The name of that App folder comes from the Dropbox app registration,
  // not from us, so it cannot carry the channel.
  //
  // Each channel therefore lives in a sub-folder of the App folder, with stable
  // keeping the flat layout it has always had. This is correct under both
  // configurations: with one shared DROPBOX_APP_KEY the sub-folder is what
  // keeps the channels apart, and with a per-channel app key (separate App
  // folders) it is merely one harmless extra level.
  static const _channelSubfolder = isStableChannel ? '' : '/$buildChannel';

  // Sub-folder names reserved by the *other* channels. Only reachable from
  // stable, whose wipe is the one operation that touches the App folder root.
  static const _foreignChannelFolders = isStableChannel
      ? {'staging', 'nightly'}
      : <String>{};

  final DropboxAuth _auth;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 120),
    ),
  );

  final Set<String> _ensuredFolders = {};

  DropboxAdapter(this._auth);

  /// Canonical Glaze path (`/Glaze-nightly/characters/x.json`) to the
  /// App-folder-relative path Dropbox expects (`/nightly/characters/x.json`).
  String _stripPrefix(String path) {
    if (path.startsWith(cloudBase)) {
      return '$_channelSubfolder${path.substring(cloudBase.length)}';
    }
    return path;
  }

  /// Inverse of [_stripPrefix] for paths coming back from the API.
  ///
  /// Drops the channel sub-folder so the rest of the sync layer keeps seeing
  /// listings relative to the Glaze root — the invariant
  /// [normalizeCloudSyncPath] relies on to line manifest entries up against
  /// `list_folder` results. Without this, every entry would look missing on a
  /// non-stable channel and sync would re-upload the whole library each run.
  String _unmapChannelPath(String path) {
    if (_channelSubfolder.isEmpty) return path;
    if (path == _channelSubfolder) return '/';
    if (path.startsWith('$_channelSubfolder/')) {
      return path.substring(_channelSubfolder.length);
    }
    return path;
  }

  /// Whether a root-relative path belongs to a channel that is not this build.
  ///
  /// Guards the App-folder-root wipe: with a shared DROPBOX_APP_KEY the other
  /// channels sit next to us in the same folder, and "delete cloud data" must
  /// not reach across into them.
  bool _belongsToAnotherChannel(String? path) {
    if (_foreignChannelFolders.isEmpty) return false;
    if (path == null || path.isEmpty) return false;
    final first = path
        .split('/')
        .firstWhere((segment) => segment.isNotEmpty, orElse: () => '');
    return _foreignChannelFolders.contains(first.toLowerCase());
  }

  Future<Map<String, String>> _headers() async {
    final token = await _auth.getValidToken();
    return {'Authorization': 'Bearer $token'};
  }

  Future<T> _apiCall<T>(
    String endpoint,
    Map<String, dynamic> body, {
    T Function(Map<String, dynamic>)? fromJson,
  }) async {
    final headers = await _headers();
    headers['Content-Type'] = 'application/json';
    final response = await _dio.post<Map<String, dynamic>>(
      '$_apiBase$endpoint',
      data: jsonEncode(body),
      options: Options(headers: headers),
    );
    if (fromJson != null && response.data != null) {
      return fromJson(response.data!);
    }
    return response.data as T;
  }

  Future<T> _retryOn401<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await _auth.getValidToken();
        return await fn();
      }
      rethrow;
    }
  }

  @override
  Future<bool> isConnected() =>
      _auth.isConnected ? Future.value(true) : Future.value(false);

  @override
  Future<void> ensureFolder(String path) async {
    final stripped = _stripPrefix(path);
    if (_ensuredFolders.contains(stripped)) return;

    final parts = stripped.split('/').where((s) => s.isNotEmpty).toList();
    var current = '';
    for (final part in parts) {
      current += '/$part';
      if (_ensuredFolders.contains(current)) continue;
      try {
        await _retryOn401(
          () => _apiCall<dynamic>('/files/create_folder_v2', {'path': current}),
        );
      } on DioException catch (e) {
        if (e.response?.statusCode != 409) rethrow;
      }
      _ensuredFolders.add(current);
    }
  }

  @override
  Future<void> upload(String path, String data) async {
    await _retryOn401(() async {
      final headers = await _headers();
      headers['Content-Type'] = 'application/octet-stream';
      headers['Dropbox-API-Arg'] = jsonEncode({
        'path': _stripPrefix(path),
        'mode': 'overwrite',
        'autorename': false,
        'mute': true,
      });
      await _dio.post<void>(
        '$_contentBase/files/upload',
        data: data,
        options: Options(headers: headers),
      );
    });
  }

  @override
  Future<void> uploadBinary(String path, Uint8List data) async {
    await _retryOn401(() async {
      final headers = await _headers();
      headers['Content-Type'] = 'application/octet-stream';
      headers['Dropbox-API-Arg'] = jsonEncode({
        'path': _stripPrefix(path),
        'mode': 'overwrite',
        'autorename': false,
        'mute': true,
      });
      await _dio.post<void>(
        '$_contentBase/files/upload',
        data: Stream.fromIterable([data]),
        options: Options(
          headers: headers,
          contentType: 'application/octet-stream',
        ),
      );
    });
  }

  @override
  Future<String> download(String path) async {
    try {
      return await _retryOn401(() async {
        final headers = await _headers();
        headers['Dropbox-API-Arg'] = jsonEncode({'path': _stripPrefix(path)});
        final response = await _dio.post<String>(
          '$_contentBase/files/download',
          options: Options(headers: headers, responseType: ResponseType.plain),
        );
        return response.data ?? '';
      });
    } on DioException catch (e) {
      if (e.response?.statusCode == 409 &&
          e.response?.data.toString().contains('not_found') == true) {
        throw CloudFileNotFoundException(path);
      }
      rethrow;
    }
  }

  @override
  Future<Uint8List> downloadBinary(String path) async {
    return _retryOn401(() async {
      final headers = await _headers();
      headers['Dropbox-API-Arg'] = jsonEncode({'path': _stripPrefix(path)});
      final response = await _dio.post<List<int>>(
        '$_contentBase/files/download',
        options: Options(headers: headers, responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data ?? []);
    });
  }

  @override
  Future<void> deleteFile(String path) async {
    await _retryOn401(
      () => _apiCall<dynamic>('/files/delete_v2', {'path': _stripPrefix(path)}),
    );
  }

  @override
  Future<void> deleteFolder(String path) async {
    final stripped = _stripPrefix(path);
    if (stripped.isEmpty) {
      await _retryOn401(() => _deleteAllInRoot());
      _ensuredFolders.clear();
      return;
    }
    await _retryOn401(
      () => _apiCall<dynamic>('/files/delete_v2', {'path': stripped}),
    );
    _ensuredFolders.remove(stripped);
  }

  Future<void> _deleteAllInRoot() async {
    final entries = <Map<String, dynamic>>[];
    var result = await _apiCall<Map<String, dynamic>>('/files/list_folder', {
      'path': '',
      'recursive': true,
    });
    entries.addAll(
      (result['entries'] as List? ?? []).cast<Map<String, dynamic>>(),
    );

    var hasMore = result['has_more'] as bool? ?? false;
    while (hasMore) {
      result = await _apiCall<Map<String, dynamic>>(
        '/files/list_folder/continue',
        {'cursor': result['cursor']},
      );
      entries.addAll(
        (result['entries'] as List? ?? []).cast<Map<String, dynamic>>(),
      );
      hasMore = result['has_more'] as bool? ?? false;
    }

    // Leave the other channels' sub-trees alone — see _belongsToAnotherChannel.
    entries.removeWhere(
      (e) => _belongsToAnotherChannel(
        (e['path_lower'] ?? e['path_display']) as String?,
      ),
    );

    if (entries.isEmpty) return;

    try {
      final result = await _apiCall<Map<String, dynamic>>(
        '/files/delete_batch',
        {
          'entries': entries
              .map((e) => {'path': e['path_lower'] ?? e['path_display']})
              .toList(),
        },
      );
      await _waitForDeleteBatch(result);
    } catch (_) {
      for (final entry in entries) {
        try {
          await _apiCall<dynamic>('/files/delete_v2', {
            'path': entry['path_lower'] ?? entry['path_display'],
          });
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  Future<void> _waitForDeleteBatch(Map<String, dynamic> result) async {
    var tag = result['.tag'] as String?;
    var asyncJobId = result['async_job_id'] as String?;

    for (
      var i = 0;
      tag == 'async_job_id' && asyncJobId != null && i < _deleteBatchPolls;
      i++
    ) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final check = await _apiCall<Map<String, dynamic>>(
        '/files/delete_batch/check',
        {'async_job_id': asyncJobId},
      );
      tag = check['.tag'] as String?;
      if (tag == 'complete') return;
      if (tag == 'failed') {
        throw Exception('Dropbox delete_batch failed: $check');
      }
    }

    if (tag == 'async_job_id') {
      throw Exception('Dropbox delete_batch did not complete in time');
    }
    if (tag == 'failed') {
      throw Exception('Dropbox delete_batch failed: $result');
    }
  }

  @override
  Future<List<CloudFileInfo>> listFolder(String path) async {
    return _retryOn401(() async {
      final result = <CloudFileInfo>[];
      var response = await _apiCall<Map<String, dynamic>>(
        '/files/list_folder',
        {'path': _stripPrefix(path), 'recursive': false},
      );
      result.addAll(_parseEntries(response['entries'] as List? ?? []));

      var hasMore = response['has_more'] as bool? ?? false;
      while (hasMore) {
        response = await _apiCall<Map<String, dynamic>>(
          '/files/list_folder/continue',
          {'cursor': response['cursor']},
        );
        result.addAll(_parseEntries(response['entries'] as List? ?? []));
        hasMore = response['has_more'] as bool? ?? false;
      }
      return result;
    });
  }

  List<CloudFileInfo> _parseEntries(List<Object?> entries) {
    return entries
        .whereType<Map<String, dynamic>>()
        // Another channel's sub-folder is not ours to see. Listing the App
        // folder root from stable would otherwise surface `nightly/` as cloud
        // content — which, among other things, kept the post-wipe
        // "waiting for cloud to finalize" poll spinning until it timed out.
        .where(
          (e) => !_belongsToAnotherChannel(
            (e['path_lower'] ?? e['path_display']) as String?,
          ),
        )
        .map(
          (e) => CloudFileInfo(
            path: _unmapChannelPath(e['path_display'] as String? ?? ''),
            name: e['name'] as String? ?? '',
            isFolder: e['.tag'] == 'folder',
          ),
        )
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> getAccountInfo() async {
    try {
      final result = await _apiCall<Map<String, dynamic>>(
        '/users/get_current_account',
        {},
      );
      return {
        'name': result['name']?['display_name'],
        'email': result['email'],
        'account_id': result['account_id'],
      };
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> invalidateFolderCache() {
    _ensuredFolders.clear();
    return Future.value();
  }
}
