import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'inline_media.dart';
import 'tokenizers/bpe_tokenizer.dart';
import 'tokenizers/tokenizer_codec.dart';
import 'tokenizers/tokenizer_kind.dart';

export 'tokenizers/tokenizer_kind.dart';

/// The tokenizer [estimateTokens] counts with, per isolate.
///
/// The UI isolate and the prompt worker each hold their own copy (isolates
/// share no memory); both load it from the same cache file written by
/// `TokenizerStore`, so they always count alike.
BpeTokenizer? _active;
TokenizerKind? _activeKind;

final _tokenCache = <String, int>{};
int _activationSeq = 0;

/// The kind [estimateTokens] currently counts with. [TokenizerKind.approx]
/// until a real tokenizer has been loaded into this isolate.
TokenizerKind get activeTokenizerKind => _activeKind ?? TokenizerKind.approx;

/// Where [kind]'s compact cache lives under the app data directory.
String tokenizerCachePath(String dataDir, TokenizerKind kind) =>
    '$dataDir/tokenizers/${kind.id}.glztok';

/// Switches this isolate to [kind], reading its cache under [dataDir].
///
/// Returns false — and keeps counting with the previous tokenizer — when the
/// cache is missing or unreadable; the caller downloads it first.
///
/// A call overtaken by a later one (the user flipped models while a large
/// vocabulary was still being read) returns false without installing
/// anything, so the latest request always wins.
Future<bool> activateTokenizer(TokenizerKind kind, String dataDir) async {
  final seq = ++_activationSeq;
  if (!kind.needsDownload) {
    _setActive(null, kind);
    return true;
  }
  if (_activeKind == kind && _active != null) return true;
  try {
    final file = File(tokenizerCachePath(dataDir, kind));
    if (!await file.exists()) return false;
    final bytes = await file.readAsBytes();
    if (seq != _activationSeq) return false;
    final tokenizer = decodeTokenizerCache(bytes);
    if (tokenizer == null) return false;
    _setActive(tokenizer, kind);
    return true;
  } catch (e) {
    debugPrint('[tokenizer] failed to load ${kind.id}: $e');
    return false;
  }
}

/// Installs an already-built tokenizer. Tests use it to count with a real
/// vocabulary without touching the file system.
@visibleForTesting
void debugSetActiveTokenizer(BpeTokenizer? tokenizer, TokenizerKind kind) =>
    _setActive(tokenizer, kind);

void _setActive(BpeTokenizer? tokenizer, TokenizerKind kind) {
  _active = tokenizer;
  _activeKind = kind;
  _tokenCache.clear();
}

/// Estimate token count for [text] with the active tokenizer, memoized.
/// Inline base64 media is counted as the placeholder the request carries
/// instead (see [stripInlineMedia]).
/// Falls back to ~4 chars/token while no tokenizer is loaded.
int estimateTokens(String text, {bool useCache = true}) {
  if (text.isEmpty) return 0;
  final cleaned = stripInlineMedia(text);
  if (cleaned.isEmpty) return 0;

  final tokenizer = _active;
  if (tokenizer == null) return _approxTokens(cleaned);

  if (!useCache) return _count(tokenizer, cleaned);

  final key = _cacheKey(cleaned);
  final cached = _tokenCache[key];
  if (cached != null) return cached;

  final count = _count(tokenizer, cleaned);
  _tokenCache[key] = count;
  return count;
}

int _count(BpeTokenizer tokenizer, String text) {
  try {
    return tokenizer.count(text);
  } catch (e) {
    debugPrint('[tokenizer] count failed: $e');
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
