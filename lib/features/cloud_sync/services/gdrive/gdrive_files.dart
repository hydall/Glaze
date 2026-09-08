import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../cloud_adapter.dart';
import 'gdrive_folders.dart';

class GDriveFiles {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 120),
    ),
  );

  final Map<String, String> _fileIdCache = {};
  final GDriveFolders _folders;
  final Future<String> Function() _getAccessToken;

  GDriveFiles(this._folders, this._getAccessToken);

  void cacheFileId(String path, String id) => _fileIdCache[path] = id;
  String? getCachedFileId(String path) => _fileIdCache[path];
  void clearFileIdCache() => _fileIdCache.clear();

  Future<String> _getToken() async => await _getAccessToken();

  Future<void> upload(String path, String data) async {
    final token = await _getToken();
    final parentId = await _folders.resolvePathToParent(path);
    final fileName = path.split('/').last;
    final cacheKey = path;

    final existingId = _fileIdCache[cacheKey];
    if (existingId != null) {
      try {
        await _dio.patch<void>(
          'https://www.googleapis.com/upload/drive/v3/files/$existingId?uploadType=media',
          data: data,
          options: Options(
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          ),
        );
        return;
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) rethrow;
        _fileIdCache.remove(cacheKey);
      }
    }

    final fileId = await _findFileByName(fileName, parentId, token);
    if (fileId != null) {
      await _dio.patch<void>(
        'https://www.googleapis.com/upload/drive/v3/files/$fileId?uploadType=media',
        data: data,
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
        ),
      );
      _fileIdCache[cacheKey] = fileId;
      return;
    }

    final boundary = 'glaze_boundary_${DateTime.now().millisecondsSinceEpoch}';
    final metadata = jsonEncode({
      'name': fileName,
      'parents': [parentId],
    });

    final body =
        '--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '$metadata\r\n'
        '--$boundary\r\n'
        'Content-Type: application/json\r\n\r\n'
        '$data\r\n'
        '--$boundary--';

    final response = await _dio.post<Map<String, dynamic>>(
      'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart',
      data: body,
      options: Options(
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'multipart/related; boundary=$boundary',
        },
      ),
    );
    final newId = response.data?['id'] as String?;
    if (newId != null) _fileIdCache[cacheKey] = newId;
  }

  Future<void> uploadBinary(String path, Uint8List data) async {
    final token = await _getToken();
    final parentId = await _folders.resolvePathToParent(path);
    final fileName = path.split('/').last;

    final existingId =
        _fileIdCache[path] ?? await _findFileByName(fileName, parentId, token);
    if (existingId != null) {
      await _dio.patch<void>(
        'https://www.googleapis.com/upload/drive/v3/files/$existingId?uploadType=media',
        data: Stream.fromIterable([data]),
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/octet-stream',
          },
          contentType: 'application/octet-stream',
        ),
      );
      _fileIdCache[path] = existingId;
      return;
    }

    final metaResponse = await _dio.post<Map<String, dynamic>>(
      'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable',
      data: jsonEncode({
        'name': fileName,
        'parents': [parentId],
      }),
      options: Options(
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      ),
    );
    final location = metaResponse.headers['location']?.first;
    if (location == null) throw Exception('No resumable upload URL');

    final uploadResponse = await _dio.put<Map<String, dynamic>>(
      location,
      data: Stream.fromIterable([data]),
      options: Options(
        headers: {'Content-Length': data.length.toString()},
        contentType: 'application/octet-stream',
      ),
    );
    final newId = uploadResponse.data?['id'] as String?;
    if (newId != null) _fileIdCache[path] = newId;
  }

  Future<String> download(String path) async {
    final token = await _getToken();
    final fileId = await _resolveFileId(path, token);
    final response = await _dio.get<String>(
      'https://www.googleapis.com/drive/v3/files/$fileId?alt=media',
      options: Options(
        headers: {'Authorization': 'Bearer $token'},
        responseType: ResponseType.plain,
      ),
    );
    return response.data ?? '';
  }

  Future<Uint8List> downloadBinary(String path) async {
    final token = await _getToken();
    final fileId = await _resolveFileId(path, token);
    final response = await _dio.get<List<int>>(
      'https://www.googleapis.com/drive/v3/files/$fileId?alt=media',
      options: Options(
        headers: {'Authorization': 'Bearer $token'},
        responseType: ResponseType.bytes,
      ),
    );
    return Uint8List.fromList(response.data ?? []);
  }

  Future<void> deleteFile(String path) async {
    final token = await _getToken();
    final fileId = await _resolveFileId(path, token);
    await _dio.delete<void>(
      'https://www.googleapis.com/drive/v3/files/$fileId',
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    _fileIdCache.remove(path);
  }

  Future<String?> _findFileByName(
    String name,
    String parentId,
    String token,
  ) async {
    try {
      final query = "name='$name' and '$parentId' in parents and trashed=false";
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

  Future<String> _resolveFileId(String path, String token) async {
    final cached = _fileIdCache[path];
    if (cached != null) return cached;

    final parentId = await _folders.resolvePathToParent(path);
    final fileName = path.split('/').last;
    final fileId = await _findFileByName(fileName, parentId, token);
    if (fileId == null) throw CloudFileNotFoundException(path);
    _fileIdCache[path] = fileId;
    return fileId;
  }
}
