import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_webview_environment.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_package_server.dart';

void main() {
  late PluginPackageServer server;
  late Uri origin;
  final files = {
    'p.one/ui/panel.html': '<p>raw</p>',
    'p.one/fonts/a.woff2': 'WOFF',
    'p.one/style.css': 'body{}',
    'p.two/secret.txt': 'two',
  };

  setUp(() async {
    server = PluginPackageServer();
    origin = (await server.start(
      (id, path) async => files.containsKey('$id/$path')
          ? Uint8List.fromList(utf8.encode(files['$id/$path']!))
          : null,
    ))!;
  });

  tearDown(() => server.stop());

  Future<HttpClientResponse> get(String url) async {
    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(Uri.parse(url));
    return request.close();
  }

  Future<String> body(HttpClientResponse r) => r.transform(utf8.decoder).join();

  test('serves package files with CORS and their types', () async {
    final font = await get('$origin/plugins/p.one/fonts/a.woff2');
    expect(font.statusCode, 200);
    expect(font.headers.value('content-type'), 'font/woff2');
    expect(font.headers.value('access-control-allow-origin'), '*');
    expect(await body(font), 'WOFF');

    final css = await get('$origin/plugins/p.one/style.css');
    expect(css.headers.value('content-type'), 'text/css; charset=utf-8');
  });

  test('a raw package page runs nothing', () async {
    final page = await get('$origin/plugins/p.one/ui/panel.html');
    expect(page.statusCode, 200);
    expect(
      page.headers.value('content-security-policy'),
      "default-src 'none'; sandbox",
    );
  });

  test('a frame document is served once, at its package path', () async {
    final url = server.openFrame('p.one', 'ui/panel.html', '<p>frame</p>')!;
    expect(url, startsWith('$origin/plugins/p.one/ui/panel.html?glaze-frame='));
    expect(server.isFrameUrl(Uri.parse(url)), isTrue);

    final first = await get(url);
    expect(first.statusCode, 200);
    expect(first.headers.value('content-security-policy'), isNull);
    expect(await body(first), '<p>frame</p>');
    expect((await get(url)).statusCode, 404);
  });

  test("a frame key opens no other plugin's address", () async {
    final url = server.openFrame('p.one', 'ui/panel.html', '<p>frame</p>')!;
    final key = Uri.parse(url).queryParameters[kPluginFrameParam];
    final other = await get(
      '$origin/plugins/p.two/ui/panel.html?$kPluginFrameParam=$key',
    );
    expect(other.statusCode, 404);
    // Still there for its own frame.
    expect((await get(url)).statusCode, 200);
  });

  test('nothing outside packages is served', () async {
    for (final path in [
      '/',
      '/plugins/p.one',
      '/plugins/p.one/missing.js',
      '/plugins/P.ONE/style.css',
    ]) {
      final r = await get('$origin$path');
      expect(r.statusCode, 404, reason: path);
    }
    // Sent as is: a client would resolve the dots away before sending.
    for (final path in [
      '/plugins/p.one/../../../etc/hosts',
      '/plugins/p.one/%2E%2E/%2E%2E/%2E%2E/etc/hosts',
    ]) {
      final socket = await Socket.connect(origin.host, origin.port);
      socket.write(
        'GET $path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      unawaited(socket.close());
      final head = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join();
      expect(head, startsWith('HTTP/1.1 404'), reason: path);
    }
  });

  test('only frame addresses pass the chat navigation policy', () async {
    // The policy reads the app's own server.
    await pluginPackageServer.start((id, path) async => null);
    addTearDown(pluginPackageServer.stop);
    final url = pluginPackageServer.openFrame('p.one', 'ui/panel.html', 'x')!;
    expect(
      chatWebViewNavigationPolicy(WebUri(url), mainFrame: false),
      NavigationActionPolicy.ALLOW,
    );
    expect(
      chatWebViewNavigationPolicy(
        WebUri('${pluginPackageServer.origin}/plugins/p.one/ui/panel.html'),
        mainFrame: false,
      ),
      NavigationActionPolicy.CANCEL,
    );
    expect(
      chatWebViewNavigationPolicy(WebUri(url), mainFrame: true),
      NavigationActionPolicy.CANCEL,
    );
  });
}
