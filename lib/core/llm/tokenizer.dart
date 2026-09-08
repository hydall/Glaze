import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../utils/platform_paths.dart';
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:tiktoken/src/common/byte_array.dart';
import 'package:tiktoken/tiktoken.dart';

const _o200kBaseVocabUrl =
    'https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken';

const _o200kBasePatStr =
    r"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+('[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])?|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*('[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])?|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+";

const _o200kCacheFile = 'o200k_base.tiktoken';

Tiktoken? _o200kBaseEncoder;

final _tokenCache = <String, int>{};

/// Loads o200k_base tokenizer. Call from main thread with no arguments,
/// or from an isolate by passing [appSupportPath] to avoid platform channels.
Future<void> preloadO200kBase({String? appSupportPath}) async {
  if (_o200kBaseEncoder != null) return;

  try {
    final dir = appSupportPath ?? await getAppDataDir();
    final cacheFile = File('$dir/$_o200kCacheFile');

    String bpeData;
    if (await cacheFile.exists()) {
      bpeData = await cacheFile.readAsString();
    } else {
      final response = await Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      )).get<String>(
        _o200kBaseVocabUrl,
        options: Options(responseType: ResponseType.plain),
      );
      bpeData = response.data!;
      await cacheFile.writeAsString(bpeData);
    }

    final mergeableRanks = <ByteArray, int>{};
    for (final line in bpeData.split('\n')) {
      if (line.isEmpty) continue;
      final parts = line.split(' ');
      if (parts.length != 2) continue;
      mergeableRanks[ByteArray.fromList(base64Decode(parts[0]))] =
          int.parse(parts[1]);
    }

    _o200kBaseEncoder = Tiktoken(
      name: 'o200k_base',
      patStr: _o200kBasePatStr,
      mergeableRanks: mergeableRanks,
      specialTokens: const {
        '<|endoftext|>': 199999,
        '<|endofprompt|>': 200018,
      },
    );

    // Smoke test
    _o200kBaseEncoder!
        .encode('test', disallowedSpecial: SpecialTokensSet.empty());
    _tokenCache.clear();
  } catch (e) {
    // Ignore tokenizer errors
  }
}

/// Convenience alias used by the isolate entry point.
Future<void> preloadO200kBaseInIsolate(String appSupportPath) =>
    preloadO200kBase(appSupportPath: appSupportPath);

bool get o200kBaseLoaded => _o200kBaseEncoder != null;

/// Estimate token count for [text] using o200k_base with persistent caching.
/// Falls back to ~4 chars/token if encoder is not yet loaded.
int estimateTokens(String text, {bool useCache = true}) {
  if (text.isEmpty) return 0;
  final cleaned = _stripBase64Media(text);
  if (cleaned.isEmpty) return 0;

  final encoder = _o200kBaseEncoder;
  if (encoder == null) return _approxTokens(cleaned);

  if (!useCache) return _encode(encoder, cleaned);

  final key = _cacheKey(cleaned);
  final cached = _tokenCache[key];
  if (cached != null) return cached;

  final count = _encode(encoder, cleaned);
  _tokenCache[key] = count;
  return count;
}

int _encode(Tiktoken encoder, String text) {
  try {
    return encoder
        .encode(text, disallowedSpecial: SpecialTokensSet.empty())
        .length;
  } catch (e) {
    debugPrint('[tokenizer] encode failed: $e');
    return _approxTokens(text);
  }
}

/// Approximate token count: ~1 token per 4 characters (rough English estimate).
int _approxTokens(String text) => (text.length / 4).ceil();

/// MD5 for long texts (>128 chars) to keep cache keys compact;
/// short texts use the text itself as the key (avoids MD5 overhead).
String _cacheKey(String text) {
  if (text.length <= 128) return text;
  return md5.convert(utf8.encode(text)).toString();
}

void clearTokenCache() => _tokenCache.clear();

/// Strips base64-encoded images/data URIs from text before token counting,
/// since they inflate char count but are not sent to the LLM.
String _stripBase64Media(String text) {
  if (text.length < 256) return text;
  var result = text.replaceAllMapped(
    RegExp(r'<img\s+src="data:image/[^"]{256,}?"\s*/?>'),
    (_) => '',
  );
  result = result.replaceAllMapped(
    RegExp(r'data:image/[^;]+;base64,[A-Za-z0-9+/=]{256,}'),
    (_) => '',
  );
  return result;
}
