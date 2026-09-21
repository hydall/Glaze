import 'dart:convert';

/// A Chub account session read out of the chub.ai page.
class ChubSession {
  final String token;
  final String? userName;
  const ChubSession({required this.token, this.userName});
}

/// JS evaluated inside a chub.ai WebView to read the session the site itself
/// keeps in `localStorage`.
///
/// chub.ai stores the API key under `URQL_TOKEN` and sends it as the
/// `Ch-Api-Key` / `samwise` request headers; the display name lives under
/// `USERNAME`. The probe returns a JSON string, or null when not signed in.
const chubSessionProbeJs = r'''
(function () {
  try {
    var token = window.localStorage.getItem('URQL_TOKEN');
    if (!token) return null;
    return JSON.stringify({
      token: token,
      user: window.localStorage.getItem('USERNAME')
    });
  } catch (e) {
    return null;
  }
})()
''';

/// Parses the result of [chubSessionProbeJs].
///
/// `evaluateJavascript` may hand the value back as the JSON string the script
/// returned or already decoded as a map, and Android sometimes returns a quoted
/// string — so a string is decoded (up to twice) before use. Returns null when
/// no usable token is present.
ChubSession? parseChubSessionProbe(Object? raw) {
  Object? value = raw;
  for (var i = 0; i < 2; i++) {
    if (value is! String) break;
    final text = value.trim();
    if (text.isEmpty) return null;
    try {
      value = jsonDecode(text);
    } on FormatException {
      return null;
    }
  }
  if (value is! Map) return null;
  final token = value['token'];
  if (token is! String || token.isEmpty) return null;
  final user = value['user'];
  return ChubSession(
    token: token,
    userName: user is String && user.isNotEmpty ? user : null,
  );
}
