import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/llm/tokenizers/tokenizer_store.dart';

import 'tokenizer_fixtures.dart';

void main() {
  late Directory dataDir;
  late HttpServer server;
  var requests = 0;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('glaze_tokenizer_store');
    requests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      requests++;
      if (request.uri.path == '/missing') {
        request.response.statusCode = 404;
      } else {
        request.response.write(jsonEncode(byteLevelTokenizerJson()));
      }
      request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await dataDir.delete(recursive: true);
    debugSetActiveTokenizer(null, TokenizerKind.approx);
  });

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  test('downloads once, converts, and both copies count alike', () async {
    final store = TokenizerStore(
      dataDir: dataDir.path,
      sources: (_) => [url('/missing'), url('/tokenizer.json')],
    );
    expect(await store.isCached(TokenizerKind.llama3), isFalse);

    await Future.wait([
      store.ensureCached(TokenizerKind.llama3),
      store.ensureCached(TokenizerKind.llama3),
    ]);
    // One failed mirror, then one shared download.
    expect(requests, 2);
    expect(await store.isCached(TokenizerKind.llama3), isTrue);
    // Only the compact cache stays behind.
    final files = dataDir
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList();
    expect(files, ['llama3.glztok']);

    expect(await activateTokenizer(TokenizerKind.llama3, dataDir.path), isTrue);
    expect(activeTokenizerKind, TokenizerKind.llama3);
    expect(estimateTokens('hello world'), 6);

    await store.ensureCached(TokenizerKind.llama3);
    expect(requests, 2);
  });

  test('a failed download leaves nothing behind and throws', () async {
    final store = TokenizerStore(
      dataDir: dataDir.path,
      sources: (_) => [url('/missing')],
    );
    await expectLater(
      store.ensureCached(TokenizerKind.qwen),
      throwsA(anything),
    );
    expect(await store.isCached(TokenizerKind.qwen), isFalse);
    expect(await activateTokenizer(TokenizerKind.qwen, dataDir.path), isFalse);
    expect(activeTokenizerKind, TokenizerKind.approx);
  });

  test('prunes the retired tiktoken vocabulary', () async {
    final legacy = File('${dataDir.path}/o200k_base.tiktoken');
    await legacy.writeAsString('stale');
    await TokenizerStore(dataDir: dataDir.path).pruneStale();
    expect(await legacy.exists(), isFalse);
  });

  test('the estimate needs no download', () async {
    final store = TokenizerStore(dataDir: dataDir.path, sources: (_) => []);
    expect(await store.isCached(TokenizerKind.approx), isTrue);
    expect(await activateTokenizer(TokenizerKind.approx, dataDir.path), isTrue);
    expect(estimateTokens('abcdefgh'), 2);
  });
}
