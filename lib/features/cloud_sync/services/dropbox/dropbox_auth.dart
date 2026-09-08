import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/services/deep_link_service.dart';
import '../oauth_local_server.dart';
import '../../sync_config.dart';

class DropboxAuth {
  static const _authBase = 'https://www.dropbox.com/oauth2/authorize';
  static const _tokenUrl = 'https://api.dropboxapi.com/oauth2/token';
  static const _revokeUrl = 'https://api.dropboxapi.com/2/auth/token/revoke';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  String? _accessToken;
  String? _refreshToken;
  int? _expiresAt;
  String? _accountId;
  String? _uid;
  String? _codeVerifier;

  String? get accessToken => _accessToken;
  bool get isConnected => _accessToken != null && _refreshToken != null;

  Map<String, dynamic>? _toStorage() => _accessToken == null
      ? null
      : {
          'access_token': _accessToken,
          'refresh_token': _refreshToken,
          'expires_at': _expiresAt,
          'account_id': _accountId,
          'uid': _uid,
        };

  void _fromStorage(Map<String, dynamic>? m) {
    if (m == null) return;
    _accessToken = m['access_token'] as String?;
    _refreshToken = m['refresh_token'] as String?;
    _expiresAt = m['expires_at'] as int?;
    _accountId = m['account_id'] as String?;
    _uid = m['uid'] as String?;
  }

  void loadTokens(Map<String, dynamic>? tokens) {
    final db = tokens?['dropbox'] as Map<String, dynamic>?;
    _fromStorage(db);
  }

  Map<String, dynamic>? saveTokens() {
    final data = _toStorage();
    return data != null ? {'dropbox': data} : null;
  }

  Future<void> connect() async {
    final appKey = SyncConfig.dropboxAppKey;
    if (appKey == null || appKey.isEmpty) {
      throw StateError('Dropbox App Key not configured');
    }

    _codeVerifier = _generateRandomString(128);
    final codeChallenge = _sha256Base64Url(_codeVerifier!);
    final state = _generateRandomString(32);

    if (Platform.isAndroid || Platform.isIOS) {
      final redirectUri = SyncConfig.dropboxRedirectNative;
      final authUrl =
          '$_authBase?response_type=code&client_id=$appKey&redirect_uri=${Uri.encodeComponent(redirectUri)}'
          '&code_challenge=$codeChallenge&code_challenge_method=S256&state=$state'
          '&token_access_type=offline';
      final deepLinkService = DeepLinkService.instance;
      await launchUrl(Uri.parse(authUrl), mode: LaunchMode.externalApplication);
      final callbackUri = await deepLinkService.waitForOAuthCallback('dropbox');
      final code = callbackUri.queryParameters['code'];
      final returnedState = callbackUri.queryParameters['state'];
      if (code == null) {
        throw StateError(
          'No authorization code in callback (uri=$callbackUri)',
        );
      }
      if (returnedState != state) {
        throw StateError(
          'OAuth state mismatch (expected=$state got=$returnedState)',
        );
      }
      await _handleCodeExchange(code, redirectUri);
      return;
    }

    final result = await OAuthLocalServer.authenticate(
      '$_authBase?response_type=code&client_id=$appKey&redirect_uri=http://localhost'
      '&code_challenge=$codeChallenge&code_challenge_method=S256&state=$state'
      '&token_access_type=offline',
    );
    await _handleCodeExchange(result.code, result.redirectUri);
  }

  Future<void> _handleCodeExchange(String code, String redirectUri) async {
    final appKey = SyncConfig.dropboxAppKey!;
    final response = await _dio.post<Map<String, dynamic>>(
      _tokenUrl,
      options: Options(
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      ),
      data:
          'code=$code&grant_type=authorization_code&client_id=$appKey&redirect_uri=${Uri.encodeComponent(redirectUri)}'
          '&code_verifier=$_codeVerifier',
    );

    final body = response.data!;
    _accessToken = body['access_token'] as String;
    _refreshToken = body['refresh_token'] as String?;
    final expiresIn = body['expires_in'] as int? ?? 14400;
    _expiresAt = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
    _accountId = body['account_id'] as String?;
    _uid = body['uid'] as String?;
  }

  Future<String> getValidToken() async {
    if (_accessToken == null) throw StateError('Not authenticated');
    if (_expiresAt != null &&
        DateTime.now().millisecondsSinceEpoch >= _expiresAt!) {
      await _refreshAccessToken();
      await _persistTokens();
    }
    return _accessToken!;
  }

  Future<void> _persistTokens() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('gz_sync_tokens');
    final existing = raw != null
        ? jsonDecode(raw) as Map<String, dynamic>
        : <String, dynamic>{};
    final saved = saveTokens();
    if (saved != null) existing.addAll(saved);
    await prefs.setString('gz_sync_tokens', jsonEncode(existing));
  }

  Future<void> _refreshAccessToken() async {
    if (_refreshToken == null) throw StateError('No refresh token');
    final appKey = SyncConfig.dropboxAppKey!;
    final response = await _dio.post<Map<String, dynamic>>(
      _tokenUrl,
      options: Options(
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      ),
      data:
          'grant_type=refresh_token&refresh_token=$_refreshToken&client_id=$appKey',
    );
    final body = response.data!;
    _accessToken = body['access_token'] as String;
    final expiresIn = body['expires_in'] as int? ?? 14400;
    _expiresAt = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
  }

  Future<void> disconnect() async {
    if (_accessToken != null) {
      try {
        await _dio.post<void>(
          _revokeUrl,
          options: Options(
            headers: {
              'Authorization': 'Bearer $_accessToken',
              'Content-Type': '',
            },
          ),
        );
      } catch (_) {}
    }
    _accessToken = null;
    _refreshToken = null;
    _expiresAt = null;
    _accountId = null;
    _uid = null;
  }

  String _generateRandomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = Random.secure();
    return List.generate(
      length,
      (_) => chars[rng.nextInt(chars.length)],
    ).join();
  }

  String _sha256Base64Url(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
}
