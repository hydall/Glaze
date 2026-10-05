import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/utils/error_format.dart';
import '../models/tts_types.dart';

/// Shared HTTP helper for TTS providers. Every provider talks to its service
/// directly — there is no SillyTavern-style server in between — so this is
/// the only network layer they need.
class TtsHttp {
  final Dio _dio;

  TtsHttp([Dio? dio])
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 180),
            ),
          );

  /// POSTs [body] (JSON map, form data or raw string) and returns the audio.
  ///
  /// The MIME type comes from the response unless [mime] pins it; services
  /// that answer `application/octet-stream` need the pin.
  Future<TtsAudio> postForAudio(
    String url, {
    Object? body,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    String? mime,
    String? contentType = 'application/json',
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.post<List<int>>(
        url,
        data: body,
        queryParameters: query,
        options: Options(
          headers: headers,
          contentType: body is FormData ? null : contentType,
          responseType: ResponseType.bytes,
        ),
        cancelToken: cancelToken,
      );
      return _audioFrom(response, mime);
    } on DioException catch (e) {
      throw await decodeByteError(e);
    }
  }

  /// GET that returns audio (Google Translate, query-string APIs).
  Future<TtsAudio> getForAudio(
    String url, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    String? mime,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.get<List<int>>(
        url,
        queryParameters: query,
        options: Options(headers: headers, responseType: ResponseType.bytes),
        cancelToken: cancelToken,
      );
      return _audioFrom(response, mime);
    } on DioException catch (e) {
      throw await decodeByteError(e);
    }
  }

  Future<dynamic> getJson(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get<dynamic>(
      url,
      queryParameters: query,
      options: Options(headers: headers, responseType: ResponseType.plain),
      cancelToken: cancelToken,
    );
    return _decodeJson(response.data);
  }

  Future<dynamic> postJson(
    String url, {
    Object? body,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.post<dynamic>(
      url,
      data: body,
      queryParameters: query,
      options: Options(
        headers: headers,
        contentType: body is FormData ? null : 'application/json',
        responseType: ResponseType.plain,
      ),
      cancelToken: cancelToken,
    );
    return _decodeJson(response.data);
  }

  /// Downloads raw bytes (a URL handed back by a JSON response).
  Future<TtsAudio> download(
    String url, {
    String? mime,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) => getForAudio(url, mime: mime, headers: headers, cancelToken: cancelToken);

  static dynamic _decodeJson(Object? data) {
    if (data is String) {
      if (data.trim().isEmpty) return null;
      try {
        return jsonDecode(data);
      } on FormatException {
        return data;
      }
    }
    return data;
  }

  static TtsAudio _audioFrom(Response<List<int>> response, String? pinned) {
    final bytes = Uint8List.fromList(response.data ?? const []);
    if (bytes.isEmpty) throw const TtsException('Empty audio response');
    final header = response.headers.value('content-type') ?? '';
    final mime = pinned ?? sniffAudioMime(bytes) ?? header;
    if (mime.startsWith('application/json') || mime.startsWith('text/')) {
      throw TtsException(
        'Expected audio, got $mime: '
        '${utf8.decode(bytes, allowMalformed: true).trim()}',
      );
    }
    return TtsAudio(bytes, mime.isEmpty ? 'audio/mpeg' : mime);
  }
}

/// Identifies common audio containers by their magic bytes. Servers often
/// mislabel audio as `application/octet-stream`, so the bytes are the more
/// reliable source.
String? sniffAudioMime(Uint8List b) {
  if (b.length < 12) return null;
  bool at(int offset, String ascii) {
    for (var i = 0; i < ascii.length; i++) {
      if (b[offset + i] != ascii.codeUnitAt(i)) return false;
    }
    return true;
  }

  if (at(0, 'RIFF') && at(8, 'WAVE')) return 'audio/wav';
  if (at(0, 'OggS')) return 'audio/ogg';
  if (at(0, 'fLaC')) return 'audio/flac';
  if (at(0, 'ID3')) return 'audio/mpeg';
  if (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) return 'audio/mpeg';
  if (at(4, 'ftyp')) return 'audio/mp4';
  if (b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) {
    return 'audio/webm';
  }
  return null;
}
