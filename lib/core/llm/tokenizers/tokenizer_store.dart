import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../tokenizer.dart';
import 'tokenizer_codec.dart';

/// Downloads tokenizers on first use and keeps their compact caches under
/// `<data dir>/tokenizers/`.
///
/// The `tokenizer.json` itself is only an intermediate: it is converted once,
/// in a background isolate, to the binary cache both isolates load, and then
/// deleted.
class TokenizerStore {
  TokenizerStore({
    required this.dataDir,
    Dio? dio,
    List<String> Function(TokenizerKind kind) sources = tokenizerSourceUrls,
  }) : _dio = dio ?? _defaultDio(),
       _sources = sources;

  final String dataDir;
  final Dio _dio;
  final List<String> Function(TokenizerKind kind) _sources;
  final _inFlight = <TokenizerKind, Future<void>>{};

  static Dio _defaultDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 120),
    ),
  );

  /// True when [kind] needs no download or its cache is readable by this
  /// build (a cache from another codec version counts as missing).
  Future<bool> isCached(TokenizerKind kind) async {
    if (!kind.needsDownload) return true;
    final file = File(tokenizerCachePath(dataDir, kind));
    if (!await file.exists()) return false;
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      return isCurrentTokenizerCache(await handle.read(16));
    } catch (_) {
      return false;
    } finally {
      await handle?.close();
    }
  }

  /// Makes [kind]'s cache exist. Concurrent calls for one kind share a single
  /// download. Throws when every source fails.
  Future<void> ensureCached(TokenizerKind kind) {
    if (!kind.needsDownload) return Future.value();
    // A block body: `remove` returns the stored future itself, and
    // whenComplete would wait on its own result.
    return _inFlight[kind] ??= _download(kind).whenComplete(() {
      _inFlight.remove(kind);
    });
  }

  Future<void> _download(TokenizerKind kind) async {
    if (await isCached(kind)) return;
    final dir = Directory('$dataDir/tokenizers');
    await dir.create(recursive: true);
    final source = '${dir.path}/${kind.id}.json.part';
    final target = tokenizerCachePath(dataDir, kind);

    Object? lastError;
    for (final url in _sources(kind)) {
      try {
        await _dio.download(url, source);
        await _convertInBackground(source, '$target.tmp');
        // A stale cache from another codec version may still sit there.
        await _deleteQuietly(target);
        await File('$target.tmp').rename(target);
        return;
      } catch (e) {
        lastError = e;
        debugPrint('[tokenizer] ${kind.id} from $url failed: $e');
      } finally {
        await _deleteQuietly(source);
        await _deleteQuietly('$target.tmp');
      }
    }
    throw lastError ?? StateError('No source for tokenizer ${kind.id}');
  }

  /// Removes caches this build can no longer read — the o200k vocabulary of
  /// the tiktoken-based counter, and caches from another codec version.
  Future<void> pruneStale() async {
    await _deleteQuietly('$dataDir/o200k_base.tiktoken');
    final dir = Directory('$dataDir/tokenizers');
    if (!await dir.exists()) return;
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      if (entry.path.endsWith('.part') || entry.path.endsWith('.tmp')) {
        await _deleteQuietly(entry.path);
      }
    }
  }

  /// Bytes on disk used by downloaded tokenizers.
  Future<int> diskUsage() async {
    final dir = Directory('$dataDir/tokenizers');
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entry in dir.list()) {
      if (entry is File) total += await entry.length();
    }
    return total;
  }
}

Future<void> _convertInBackground(String source, String target) =>
    Isolate.run(() => _convert(source, target));

/// Background-isolate body: `tokenizer.json` → binary cache.
Future<void> _convert(String source, String target) async {
  final json =
      jsonDecode(await File(source).readAsString()) as Map<String, dynamic>;
  final tokenizer = tokenizerFromHfJson(json);
  await File(target).writeAsBytes(encodeTokenizerCache(tokenizer), flush: true);
}

Future<void> _deleteQuietly(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {}
}
