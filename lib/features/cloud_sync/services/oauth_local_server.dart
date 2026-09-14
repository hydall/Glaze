import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/oauth_state.dart';

/// The authorization code carried by a loopback redirect's [params], or a
/// thrown error saying why there is none.
///
/// Separate from the request handler so the desktop flow's checks can be run
/// without a browser, and so all three outcomes produce one sentence each
/// instead of three shapes of HTML deciding what the error says.
@visibleForTesting
String oauthCodeFromRedirect(
  Map<String, String> params, {
  String? expectedState,
}) {
  if (params.containsKey('code')) {
    // The desktop flow sends a `state` exactly as the mobile one does and
    // never looked at what came back, so any page that reached the loopback
    // port while it was open could hand Glaze an authorization code — binding
    // the reader's app to whichever account issued it.
    final mismatch = oauthStateMismatchMessage(expectedState, params['state']);
    if (mismatch != null) throw StateError(mismatch);
    return params['code']!;
  }
  if (params.containsKey('error')) {
    final error = params['error'] ?? 'unknown';
    final desc = params['error_description'] ?? '';
    throw Exception('OAuth error: $error $desc');
  }
  throw Exception('No authorization code received');
}

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
    // Read from the request being made rather than passed in alongside it, so
    // it cannot drift away from what the provider was actually asked.
    final expectedState = Uri.parse(authUrl).queryParameters['state'];

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    final redirectUri = 'http://localhost:$port';
    final url = authUrl.replaceAll(
      RegExp(r'redirect_uri=[^&]+'),
      'redirect_uri=${Uri.encodeComponent(redirectUri)}',
    );

    final codeCompleter = Completer<String>();

    server.listen((request) async {
      final response = request.response;
      try {
        final code = oauthCodeFromRedirect(
          request.uri.queryParameters,
          expectedState: expectedState,
        );
        response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(_successHtml);
        await response.close();
        codeCompleter.complete(code);
      } catch (e) {
        final message = e is StateError ? e.message : '$e';
        response
          ..statusCode = 400
          ..headers.contentType = ContentType.html
          ..write(_errorHtml.replaceAll('id="err">', 'id="err">$message'));
        await response.close();
        codeCompleter.completeError(e);
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
