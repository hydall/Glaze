import 'package:dio/dio.dart';

import 'translation_languages.dart';
import 'translation_providers.dart';

/// A machine-translation request that came back unusable — a missing key, a
/// rejected request or an empty body.
class MachineTranslationException implements Exception {
  final String message;

  const MachineTranslationException(this.message);

  @override
  String toString() => message;
}

/// The dedicated machine-translation services, each behind its own HTTP shape.
///
/// All of them are asked to treat the text as HTML (`tag_handling` / `format`),
/// so a message carrying markup comes back with its tags intact instead of
/// mangled into entities. That is the whole reason this is a client of its own
/// rather than a plain "POST the string" call.
///
/// No key is ever logged. The whole body it sends is the one text it is handed,
/// so a translation can never carry chat history off the device.
class MachineTranslationClient {
  final Dio _dio;

  MachineTranslationClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
            ),
          );

  Future<String> translate({
    required TranslationProvider provider,
    required String text,
    required TranslationLanguage target,
    required String apiKey,
    required String endpoint,
    required String folderId,
    CancelToken? cancelToken,
  }) async {
    if (provider == TranslationProvider.llm) {
      throw const MachineTranslationException('Not a machine translation');
    }
    final resolvedEndpoint = endpoint.trim().isEmpty
        ? provider.defaultEndpoint
        : endpoint.trim();
    if (resolvedEndpoint.isEmpty) {
      throw const MachineTranslationException('No endpoint configured');
    }
    if (provider.needsApiKey && apiKey.trim().isEmpty) {
      throw const MachineTranslationException('No API key configured');
    }

    final Response<dynamic> response;
    try {
      response = switch (provider) {
        TranslationProvider.deepl => await _deepL(
          text: text,
          target: target,
          apiKey: apiKey,
          endpoint: resolvedEndpoint,
          cancelToken: cancelToken,
        ),
        TranslationProvider.google => await _google(
          text: text,
          target: target,
          apiKey: apiKey,
          endpoint: resolvedEndpoint,
          cancelToken: cancelToken,
        ),
        TranslationProvider.yandex => await _yandex(
          text: text,
          target: target,
          apiKey: apiKey,
          endpoint: resolvedEndpoint,
          folderId: folderId,
          cancelToken: cancelToken,
        ),
        TranslationProvider.libretranslate => await _libre(
          text: text,
          target: target,
          apiKey: apiKey,
          endpoint: resolvedEndpoint,
          cancelToken: cancelToken,
        ),
        TranslationProvider.llm => throw StateError('unreachable'),
      };
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw MachineTranslationException(_describe(e));
    }

    final translated = _extract(provider, response.data).trim();
    if (translated.isEmpty) {
      throw const MachineTranslationException(
        'The translator returned no text',
      );
    }
    return translated;
  }

  Future<Response<dynamic>> _deepL({
    required String text,
    required TranslationLanguage target,
    required String apiKey,
    required String endpoint,
    CancelToken? cancelToken,
  }) => _dio.post<dynamic>(
    endpoint,
    data: {
      'text': [text],
      'target_lang': _deepLCode(target.code),
      'tag_handling': 'html',
    },
    options: Options(headers: {'Authorization': 'DeepL-Auth-Key $apiKey'}),
    cancelToken: cancelToken,
  );

  Future<Response<dynamic>> _google({
    required String text,
    required TranslationLanguage target,
    required String apiKey,
    required String endpoint,
    CancelToken? cancelToken,
  }) => _dio.post<dynamic>(
    endpoint,
    queryParameters: {'key': apiKey},
    data: {
      'q': [text],
      'target': target.code,
      'format': 'html',
    },
    cancelToken: cancelToken,
  );

  Future<Response<dynamic>> _yandex({
    required String text,
    required TranslationLanguage target,
    required String apiKey,
    required String endpoint,
    required String folderId,
    CancelToken? cancelToken,
  }) => _dio.post<dynamic>(
    endpoint,
    data: {
      'texts': [text],
      'targetLanguageCode': target.code,
      'format': 'HTML',
      if (folderId.trim().isNotEmpty) 'folderId': folderId.trim(),
    },
    options: Options(headers: {'Authorization': 'Api-Key $apiKey'}),
    cancelToken: cancelToken,
  );

  Future<Response<dynamic>> _libre({
    required String text,
    required TranslationLanguage target,
    required String apiKey,
    required String endpoint,
    CancelToken? cancelToken,
  }) {
    final url = endpoint.endsWith('/translate')
        ? endpoint
        : '${endpoint.replaceAll(RegExp(r'/+$'), '')}/translate';
    return _dio.post<dynamic>(
      url,
      data: {
        'q': text,
        'source': 'auto',
        'target': target.code,
        'format': 'html',
        if (apiKey.trim().isNotEmpty) 'api_key': apiKey,
      },
      cancelToken: cancelToken,
    );
  }

  /// Pulls the translated string out of each provider's response envelope.
  static String _extract(TranslationProvider provider, dynamic data) {
    if (data is! Map) return '';
    if (provider == TranslationProvider.libretranslate) {
      return (data['translatedText'] ?? '').toString();
    }
    if (provider == TranslationProvider.google) {
      final inner = data['data'];
      final list = inner is Map ? inner['translations'] : null;
      return _firstText(list, htmlEntities: true);
    }
    // DeepL and Yandex both answer with `translations: [{ text: ... }]`.
    return _firstText(data['translations']);
  }

  static String _firstText(dynamic list, {bool htmlEntities = false}) {
    if (list is! List || list.isEmpty || list.first is! Map) return '';
    final first = list.first as Map;
    final text = (first['translatedText'] ?? first['text'] ?? '').toString();
    return htmlEntities ? _decodeEntities(text) : text;
  }

  /// DeepL wants upper-case targets and a regional variant for a few of them.
  static String _deepLCode(String code) => switch (code) {
    'en' => 'EN-US',
    'pt' => 'PT-BR',
    _ => code.toUpperCase(),
  };

  /// Google's HTML mode escapes entities in the prose it returns; these five
  /// are the ones it emits for ordinary text (`'`, `"`, `&`, `<`, `>`). Tags
  /// are returned as tags and are left alone.
  static String _decodeEntities(String text) => text
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  static String _describe(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    final detail = data is Map && data['message'] is String
        ? ' ${data['message']}'
        : '';
    if (status != null) return 'HTTP $status$detail';
    return e.message ?? 'Network error';
  }
}
