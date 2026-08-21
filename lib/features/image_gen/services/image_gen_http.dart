import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class ImageGenHttp {
  final Dio _dio;

  ImageGenHttp()
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(seconds: 300),
        ),
      );

  Future<Map<String, dynamic>> post({
    required String url,
    required Map<String, dynamic> body,
    String? apiKey,
    Map<String, String>? extraHeaders,
    CancelToken? cancelToken,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (apiKey != null && apiKey.isNotEmpty)
        'Authorization': 'Bearer $apiKey',
      ...?extraHeaders,
    };
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        url,
        data: body,
        options: Options(headers: headers),
        cancelToken: cancelToken,
      );
      return response.data ?? {};
    } on DioException {
      rethrow;
    }
  }

  Future<String> postAndExtractBase64({
    required String url,
    required Map<String, dynamic> body,
    String? apiKey,
    Map<String, String>? extraHeaders,
    CancelToken? cancelToken,
    required String Function(Map<String, dynamic>) extractBase64,
  }) async {
    final json = await post(
      url: url,
      body: body,
      apiKey: apiKey,
      extraHeaders: extraHeaders,
      cancelToken: cancelToken,
    );
    final b64 = extractBase64(json);
    return b64;
  }

  /// Generic post + extract that allows the caller to return [Uint8List]
  /// directly — supports both base64 and URL-download paths.
  Future<Uint8List> postAndExtract({
    required String url,
    required Map<String, dynamic> body,
    String? apiKey,
    Map<String, String>? extraHeaders,
    CancelToken? cancelToken,
    required Future<Uint8List> Function(Map<String, dynamic>) extract,
  }) async {
    final json = await post(
      url: url,
      body: body,
      apiKey: apiKey,
      extraHeaders: extraHeaders,
      cancelToken: cancelToken,
    );
    return await extract(json);
  }

  /// Plain JSON GET (job polling, model listings).
  Future<Map<String, dynamic>> getJson({
    required String url,
    String? apiKey,
    Map<String, String>? extraHeaders,
    CancelToken? cancelToken,
  }) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      if (apiKey != null && apiKey.isNotEmpty)
        'Authorization': 'Bearer $apiKey',
      ...?extraHeaders,
    };
    final response = await _dio.get<Map<String, dynamic>>(
      url,
      options: Options(headers: headers),
      cancelToken: cancelToken,
    );
    return response.data ?? {};
  }

  /// Downloads raw bytes from a URL (for endpoints that return `url` instead
  /// of `b64_json`).
  static Future<Uint8List> downloadImage(
    String url, {
    CancelToken? cancelToken,
  }) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 120),
      ),
    );
    try {
      final response = await dio.get<Uint8List>(
        url,
        options: Options(responseType: ResponseType.bytes),
        cancelToken: cancelToken,
      );
      return response.data ?? Uint8List(0);
    } finally {
      dio.close();
    }
  }

  /// Strips an optional `data:image/...;base64,` prefix from a base64 string.
  static String stripBase64Prefix(String b64) {
    final commaIdx = b64.indexOf(',');
    if (commaIdx >= 0 && b64.startsWith('data:')) {
      return b64.substring(commaIdx + 1);
    }
    return b64;
  }

  static Uint8List base64ToBytes(String b64) {
    return base64Decode(b64);
  }

  Future<Response<Uint8List>> getRaw(
    String url, {
    CancelToken? cancelToken,
  }) async {
    return _dio.get<Uint8List>(
      url,
      options: Options(responseType: ResponseType.bytes),
      cancelToken: cancelToken,
    );
  }

  static String bytesToDataUrl(Uint8List bytes, {String mime = 'image/png'}) {
    return 'data:$mime;base64,${base64Encode(bytes)}';
  }

  /// Sends a multipart/form-data POST and returns the parsed JSON response.
  /// [imageFields] — list of (fieldName, bytes, filename, mimeType) tuples.
  /// [fields] — plain string fields to include in the form.
  Future<Map<String, dynamic>> postMultipart({
    required String url,
    required Map<String, String> fields,
    required List<(String, Uint8List, String, String)> imageFields,
    String? apiKey,
    CancelToken? cancelToken,
  }) async {
    final formData = FormData();
    for (final entry in fields.entries) {
      formData.fields.add(MapEntry(entry.key, entry.value));
    }
    for (final (fieldName, bytes, filename, mime) in imageFields) {
      formData.files.add(
        MapEntry(
          fieldName,
          MultipartFile.fromBytes(
            bytes,
            filename: filename,
            contentType: DioMediaType.parse(mime),
          ),
        ),
      );
    }
    final headers = <String, String>{
      if (apiKey != null && apiKey.isNotEmpty)
        'Authorization': 'Bearer $apiKey',
    };
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        url,
        data: formData,
        options: Options(headers: headers),
        cancelToken: cancelToken,
      );
      return response.data ?? {};
    } on DioException {
      rethrow;
    }
  }
}
