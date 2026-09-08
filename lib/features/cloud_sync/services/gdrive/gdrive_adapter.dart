import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../cloud_adapter.dart';
import '../../sync_models.dart';
import 'gdrive_auth.dart';
import 'gdrive_files.dart';
import 'gdrive_folders.dart';

class GDriveAdapter implements CloudAdapter {
  final GDriveAuth _auth;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );
  late final GDriveFolders _folders;
  late final GDriveFiles _files;

  GDriveAdapter(this._auth) {
    _folders = GDriveFolders(_auth.getValidToken);
    _files = GDriveFiles(_folders, _auth.getValidToken);
  }

  @override
  Future<bool> isConnected() => Future.value(_auth.isConnected);

  @override
  Future<void> ensureFolder(String path) async {
    if (!path.startsWith(cloudBase)) {
      path = '$cloudBase/$path';
    }
    await _folders.ensureFolder(path);
  }

  @override
  Future<void> upload(String path, String data) async {
    await _ensureParent(path);
    await _files.upload(path, data);
  }

  @override
  Future<void> uploadBinary(String path, Uint8List data) async {
    await _ensureParent(path);
    await _files.uploadBinary(path, data);
  }

  @override
  Future<String> download(String path) => _files.download(path);

  @override
  Future<Uint8List> downloadBinary(String path) => _files.downloadBinary(path);

  @override
  Future<void> deleteFile(String path) => _files.deleteFile(path);

  @override
  Future<void> deleteFolder(String path) => _folders.deleteFolder(path);

  @override
  Future<List<CloudFileInfo>> listFolder(String path) async {
    final token = await _auth.getValidToken();
    final folderId = await _folders.ensureFolder(path);

    final result = <CloudFileInfo>[];
    String? pageToken;

    do {
      final queryParams = <String, dynamic>{
        'q': "'$folderId' in parents and trashed=false",
        'fields': 'nextPageToken,files(id,name,mimeType)',
        'pageSize': 100,
      };
      if (pageToken != null) queryParams['pageToken'] = pageToken;

      final response = await _dio.get<Map<String, dynamic>>(
        'https://www.googleapis.com/drive/v3/files',
        queryParameters: queryParams,
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );

      final files = response.data?['files'] as List? ?? [];
      for (final f in files.whereType<Map<String, dynamic>>()) {
        result.add(
          CloudFileInfo(
            path: '$path/${f['name']}',
            name: f['name'] as String? ?? '',
            isFolder: f['mimeType'] == 'application/vnd.google-apps.folder',
          ),
        );
      }
      pageToken = response.data?['nextPageToken'] as String?;
    } while (pageToken != null);

    return result;
  }

  @override
  Future<Map<String, dynamic>?> getAccountInfo() => _auth.getAccountInfo();

  @override
  Future<void> invalidateFolderCache() {
    _folders.invalidateCache();
    _files.clearFileIdCache();
    return Future.value();
  }

  String? get glazeFolderId => _folders.glazeFolderId;

  Future<String> getGlazeFolderId() => _folders.getGlazeFolderId();

  Future<void> _ensureParent(String path) async {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length < 2) return;
    final folderPath = '/${parts.sublist(0, parts.length - 1).join('/')}';
    await _folders.ensureFolder(folderPath);
  }
}
