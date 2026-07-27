import 'dart:convert';

import 'package:dio/dio.dart';

import '../../sync_models.dart';

class GDriveFolders {
  // Per-channel, so stable / staging / nightly get sibling folders in the
  // user's Drive root instead of writing into one shared tree.
  static const _folderName = cloudRootFolderName;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  final Map<String, String> _folderIdCache = {};
  String? _glazeFolderId;
  final Future<String> Function() _getAccessToken;

  GDriveFolders(this._getAccessToken);

  String? get glazeFolderId => _glazeFolderId;

  void setGlazeFolderId(String? v) => _glazeFolderId = v;

  void invalidateCache() {
    _folderIdCache.clear();
    _glazeFolderId = null;
  }

  Future<String> getGlazeFolderId() async {
    if (_glazeFolderId != null) return _glazeFolderId!;
    final token = await _getAccessToken();

    final found = await _findFolderByName(_folderName, 'root', token);
    if (found != null) {
      _glazeFolderId = found;
      _folderIdCache['/$_folderName'] = found;
      return found;
    }

    return await createFolder(_folderName, 'root');
  }

  Future<String> ensureFolder(String path) async {
    final cached = _folderIdCache[path];
    if (cached != null) return cached;

    final token = await _getAccessToken();
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();

    var parentId = 'root';
    var currentPath = '';

    for (final part in parts) {
      currentPath += '/$part';
      final cachedId = _folderIdCache[currentPath];
      if (cachedId != null) {
        parentId = cachedId;
        continue;
      }

      var folderId = await _findFolderByName(part, parentId, token);
      folderId ??= await createFolder(part, parentId);
      _folderIdCache[currentPath] = folderId;
      parentId = folderId;
    }

    _folderIdCache[path] = parentId;
    return parentId;
  }

  Future<String> resolvePathToParent(String path) async {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length < 2) return await getGlazeFolderId();

    final folderParts = parts.sublist(0, parts.length - 1);
    final folderPath = '/${folderParts.join('/')}';
    return await ensureFolder(folderPath);
  }

  Future<String> createFolder(String name, String parentId) async {
    final token = await _getAccessToken();
    final response = await _dio.post<Map<String, dynamic>>(
      'https://www.googleapis.com/drive/v3/files',
      data: jsonEncode({
        'name': name,
        'mimeType': 'application/vnd.google-apps.folder',
        'parents': [parentId],
      }),
      options: Options(
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      ),
    );
    final id = response.data?['id'] as String;
    return id;
  }

  Future<void> deleteFolder(String path) async {
    final token = await _getAccessToken();
    var folderId = _folderIdCache[path];
    if (folderId == null && path == '/$_folderName') {
      folderId = await _findFolderByName(_folderName, 'root', token);
    }
    if (folderId == null) {
      return;
    }
    await _dio.delete<void>(
      'https://www.googleapis.com/drive/v3/files/$folderId',
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    _folderIdCache.remove(path);
    if (path == '/$_folderName') _glazeFolderId = null;
  }

  Future<String?> _findFolderByName(
    String name,
    String parentId,
    String token,
  ) async {
    try {
      final query =
          "name='$name' and '$parentId' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false";
      final response = await _dio.get<Map<String, dynamic>>(
        'https://www.googleapis.com/drive/v3/files',
        queryParameters: {'q': query, 'fields': 'files(id,name)'},
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final files = response.data?['files'] as List? ?? [];
      if (files.isEmpty) return null;
      return files[0]['id'] as String;
    } catch (_) {
      return null;
    }
  }
}
