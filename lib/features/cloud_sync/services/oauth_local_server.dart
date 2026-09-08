import 'dart:async';
import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

class OAuthLocalServer {
  static const _successHtml = '''<!DOCTYPE html>
<html><head><title>Glaze — Connected</title></head>
<body style="background:#1A1A2E;color:#fff;display:flex;align-items:center;justify-content:center;height:100vh;font-family:sans-serif">
<div style="text-align:center">
<h1>Connected!</h1>
<p>You can close this tab and return to Glaze.</p>
</div></body></html>''';

  static const _errorHtml = '''<!DOCTYPE html>
<html><head><title>Glaze — Error</title></head>
<body style="background:#1A1A2E;color:#ff6b6b;display:flex;align-items:center;justify-content:center;height:100vh;font-family:sans-serif">
<div style="text-align:center">
<h1>Authentication Failed</h1>
<p id="err"></p>
<p>You can close this tab and return to Glaze.</p>
</div></body></html>''';

  static Future<({String code, String redirectUri})> authenticate(
    String authUrl, {
    String successPattern = 'code=',
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    final redirectUri = 'http://localhost:$port';
    final url = authUrl.replaceAll(
      RegExp(r'redirect_uri=[^&]+'),
      'redirect_uri=${Uri.encodeComponent(redirectUri)}',
    );

    final codeCompleter = Completer<String>();

    server.listen((request) async {
      final params = request.uri.queryParameters;
      final response = request.response;

      if (params.containsKey('code')) {
        response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(_successHtml);
        await response.close();
        codeCompleter.complete(params['code']!);
      } else if (params.containsKey('error')) {
        final error = params['error'] ?? 'unknown';
        final desc = params['error_description'] ?? '';
        response
          ..statusCode = 400
          ..headers.contentType = ContentType.html
          ..write(_errorHtml.replaceAll('id="err">', 'id="err">$error: $desc'));
        await response.close();
        codeCompleter.completeError(Exception('OAuth error: $error $desc'));
      } else {
        response
          ..statusCode = 400
          ..headers.contentType = ContentType.html
          ..write(
            _errorHtml.replaceAll('id="err">', 'id="err">No code in response'),
          );
        await response.close();
        codeCompleter.completeError(
          Exception('No authorization code received'),
        );
      }

      await server.close(force: true);
    });

    final launched = await launchUrl(Uri.parse(url));
    if (!launched) {
      await server.close(force: true);
      throw Exception('Could not launch browser for OAuth');
    }

    final code = await codeCompleter.future.timeout(
      timeout,
      onTimeout: () {
        server.close(force: true);
        throw TimeoutException('OAuth flow timed out', timeout);
      },
    );
    return (code: code, redirectUri: redirectUri);
  }
}
