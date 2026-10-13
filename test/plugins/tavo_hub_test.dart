import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/plugins/compat/tavo/tavo_hub.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_package_reader.dart';
import 'package:glaze_flutter/features/plugins/services/plugin_store.dart';

import 'package:archive/archive.dart';

import 'plugin_package_test.dart' show manifest, packageFiles, zip;

/// Answers by the first path fragment that matches; 404 otherwise.
class _Hub implements HttpClientAdapter {
  _Hub(this.routes);

  final Map<String, Object> routes;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final key = routes.keys
        .where((k) => options.uri.toString().contains(k))
        .firstOrNull;
    if (key == null) {
      return ResponseBody.fromString(
        '{"error":{"code":"not_found","message":"plugin not found"}}',
        404,
        headers: _json,
      );
    }
    final body = routes[key]!;
    if (body is Uint8List) {
      return ResponseBody.fromBytes(body, 200);
    }
    return ResponseBody.fromString(jsonEncode(body), 200, headers: _json);
  }
}

const _json = {
  Headers.contentTypeHeader: [Headers.jsonContentType],
};

Map<String, Object?> detail({String version = '1.1.0'}) => {
  'slug': 'quick-note',
  'package_id': 'com.example.note',
  'name': 'Quick Note',
  'author': 'Example',
  'description': 'Notes.',
  'published_version': version,
  'download_count': 74,
  'access_type': 'free',
  'icon_url': 'https://tavoai.dev/plugins/x/cover.png',
  'published_at': '2026-10-13T07:32:39.737000',
  'review': {
    'safety': {'verdict': 'warn'},
  },
  'versions': [
    {'version': version, 'changelog': 'Faster.'},
    {'version': '1.0.0', 'changelog': 'First.'},
  ],
};

TavoHubClient _client(_Hub hub) =>
    TavoHubClient(Dio()..httpClientAdapter = hub);

void main() {
  group('tavoHubPluginRef', () {
    test('reads the slug or package id of a plugin page', () {
      for (final (url, ref) in [
        ('https://hub.tavoai.dev/plugins/package/pusya.social', 'pusya.social'),
        ('https://hub.tavoai.dev/plugins/pusya-social', 'pusya-social'),
        (
          'https://hub.tavoai.dev/webview/plugins/pusya-social?x=1',
          'pusya-social',
        ),
        ('https://hub.tavoai.dev/plugin-market/package/a.b', 'a.b'),
        ('https://HUB.tavoai.dev/plugins/a/', 'a'),
      ]) {
        expect(tavoHubPluginRef(Uri.parse(url)), ref, reason: url);
      }
    });

    test('ignores everything else', () {
      for (final url in [
        'https://hub.tavoai.dev/plugins',
        'https://hub.tavoai.dev/themes/abc',
        'https://hub.tavoai.dev/plugins/a/edit',
        'https://hub.tavoai.dev/plugins/..',
        'https://evil.example/plugins/a',
        'https://hub.tavoai.dev.evil.example/plugins/a',
        'ftp://hub.tavoai.dev/plugins/a',
      ]) {
        expect(tavoHubPluginRef(Uri.parse(url)), isNull, reason: url);
      }
    });
  });

  test('isNewerPluginVersion compares dotted numbers and pre-releases', () {
    expect(isNewerPluginVersion('1.1.1', '1.1.0'), isTrue);
    expect(isNewerPluginVersion('1.10.0', '1.9.9'), isTrue);
    expect(isNewerPluginVersion('1.1.0', '1.1.0'), isFalse);
    expect(isNewerPluginVersion('1.0.0', '1.1.0'), isFalse);
    expect(isNewerPluginVersion('1.0.0', '1.0.0-beta'), isTrue);
    expect(isNewerPluginVersion('1.0.0-beta', '1.0.0'), isFalse);
  });

  test('isTavoHubDownloadUrl takes only the hub hosts over https', () {
    expect(
      isTavoHubDownloadUrl(Uri.parse('https://hub.tavoai.dev/x-plugins/a.tpg')),
      isTrue,
    );
    expect(
      isTavoHubDownloadUrl(Uri.parse('http://hub.tavoai.dev/x-plugins/a.tpg')),
      isFalse,
    );
    expect(
      isTavoHubDownloadUrl(Uri.parse('https://nottavoai.dev/a.tpg')),
      isFalse,
    );
  });

  test('plugin() reads what the hub says', () async {
    final p = await _client(
      _Hub({'/plugins/quick-note': detail()}),
    ).plugin('quick-note');
    expect(p.slug, 'quick-note');
    expect(p.packageId, 'com.example.note');
    expect(p.version, '1.1.0');
    expect(p.changelog, 'Faster.');
    expect(p.downloads, 74);
    expect(p.safety, 'warn');
    expect(p.free, isTrue);
    expect(p.pageUrl.toString(), 'https://hub.tavoai.dev/plugins/quick-note');
  });

  test('plugin() reports a missing plugin', () async {
    await expectLater(
      _client(_Hub({})).plugin('nope'),
      throwsA(isA<TavoHubException>()),
    );
  });

  test('lookup() returns the plugins the hub knows', () async {
    final hub = _Hub({
      '/plugins/lookup': {
        'items': [
          {'package_id': 'com.example.note', 'plugin': detail()},
          {'package_id': 'gone.plugin', 'plugin': null},
        ],
      },
    });
    final found = await _client(
      hub,
    ).lookup(['com.example.note', 'gone.plugin']);
    expect(found.keys, ['com.example.note']);
    expect(hub.requests.single.method, 'POST');
  });

  group('download()', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final plugin = TavoHubPlugin.fromJson(detail());

    Map<String, Object> routes(String url, String sha) => {
      '/download-url': {'url': url, 'sha256': sha},
      'x-plugins': bytes,
    };

    test('returns the package when the checksum matches', () async {
      final got = await _client(
        _Hub(
          routes(
            'https://hub.tavoai.dev/x-plugins/a.tpg',
            sha256.convert(bytes).toString(),
          ),
        ),
      ).download(plugin);
      expect(got, bytes);
    });

    test('refuses a damaged package', () async {
      await expectLater(
        _client(
          _Hub(routes('https://hub.tavoai.dev/x-plugins/a.tpg', '00')),
        ).download(plugin),
        throwsA(isA<TavoHubException>()),
      );
    });

    test('refuses a link off the hub', () async {
      final hub = _Hub(
        routes(
          'https://evil.example/x-plugins/a.tpg',
          sha256.convert(bytes).toString(),
        ),
      );
      await expectLater(
        _client(hub).download(plugin),
        throwsA(isA<TavoHubException>()),
      );
      expect(hub.requests, hasLength(1));
    });
  });

  group('PluginStore keeps where a plugin came from', () {
    late Directory temp;
    late PluginStore store;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('plugin_hub_test');
      store = PluginStore(root: '${temp.path}/p', dataRoot: '${temp.path}/d');
    });

    tearDown(() => temp.delete(recursive: true));

    PluginPackage package({String author = 'Example'}) =>
        readPluginPackage(zip(packageFiles(m: manifest({'author': author}))));

    test('a hub install is marked and the mark survives a reload', () async {
      final installed = await store.install(package(), hubSlug: 'quick-note');
      expect(installed.hubSlug, 'quick-note');
      expect((await store.loadAll()).single.hubSlug, 'quick-note');
    });

    test('an update from a file keeps the mark', () async {
      await store.install(package(), hubSlug: 'quick-note');
      final updated = await store.install(package());
      expect(updated.hubSlug, 'quick-note');
    });

    test('another author drops the mark', () async {
      await store.install(package(), hubSlug: 'quick-note');
      final other = await store.install(package(author: 'Someone else'));
      expect(other.hubSlug, isNull);
    });

    test('a file install has no mark', () async {
      expect((await store.install(package())).hubSlug, isNull);
    });

    test('saving keeps the mark', () async {
      final installed = await store.install(package(), hubSlug: 'quick-note');
      await store.save(installed.copyWith(enabled: false));
      expect((await store.loadAll()).single.hubSlug, 'quick-note');
    });
  });

  group('PluginStore.exportPackage', () {
    late Directory temp;
    late PluginStore store;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('plugin_export_test');
      store = PluginStore(root: '${temp.path}/p', dataRoot: '${temp.path}/d');
    });

    tearDown(() => temp.delete(recursive: true));

    Set<String> names(Uint8List bytes) => {
      for (final f in ZipDecoder().decodeBytes(bytes))
        if (f.isFile) f.name,
    };

    test('a Glaze plugin goes out with its plugin.json', () async {
      final files = packageFiles();
      await store.install(readPluginPackage(zip(files)));
      final out = await store.exportPackage('com.example.note');
      expect(names(out), files.keys.toSet());
      expect(readPluginPackage(out).manifest.id, 'com.example.note');
    });

    test('a converted plugin goes out as it came in', () async {
      final files = packageFiles(manifestFile: 'manifest.json');
      final installed = await store.install(readPluginPackage(zip(files)));
      final out = await store.exportPackage(installed.id);
      expect(names(out), files.keys.toSet());
      expect(names(out), isNot(contains('plugin.json')));
      expect(readPluginPackage(out).manifest.id, installed.id);
    });
  });
}
