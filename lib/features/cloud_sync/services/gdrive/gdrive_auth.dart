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

class GDriveAuth {
  static const _authBase = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenUrl = 'https://oauth2.googleapis.com/token';
  static const _revokeUrl = 'https://oauth2.googleapis.com/revoke';
  static const _userInfoUrl = 'https://www.googleapis.com/oauth2/v2/userinfo';
  static const _scope = 'https://www.googleapis.com/auth/drive.file';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  String? _accessToken;
  String? _refreshToken;
  int? _expiresAt;
  String? _folderId;
  String? _codeVerifier;

  String? get accessToken => _accessToken;
  String? get folderId => _folderId;
  bool get isConnected => _accessToken != null && _refreshToken != null;

  void loadTokens(Map<String, dynamic>? tokens) {
    final gd = tokens?['gdrive'] as Map<String, dynamic>?;
    if (gd == null) return;
    _accessToken = gd['access_token'] as String?;
    _refreshToken = gd['refresh_token'] as String?;
    _expiresAt = gd['expires_at'] as int?;
    _folderId = gd['folderId'] as String?;
  }

  Map<String, dynamic>? saveTokens() {
    if (_accessToken == null) return null;
    return {
      'gdrive': {
        'access_token': _accessToken,
        'refresh_token': _refreshToken,
        'expires_at': _expiresAt,
        'folderId': _folderId,
      },
    };
  }

  Future<void> connect() async {
    final clientId = SyncConfig.gdriveClientId;
    if (clientId == null || clientId.isEmpty) {
      throw StateError('GDrive Client ID not configured');
    }

    _codeVerifier = _generateRandomString(128);
    final codeChallenge = _sha256Base64Url(_codeVerifier!);
    final state = _generateRandomString(32);

    if (Platform.isAndroid || Platform.isIOS) {
      final redirectUri = SyncConfig.gdriveRedirectNative;
      final authUrl =
          '$_authBase?response_type=code&client_id=$clientId&redirect_uri=${Uri.encodeComponent(redirectUri)}'
          '&scope=${Uri.encodeComponent(_scope)}&code_challenge=$codeChallenge&code_challenge_method=S256&state=$state'
          '&access_type=offline&prompt=consent';
      final deepLinkService = DeepLinkService.instance;
      await launchUrl(Uri.parse(authUrl), mode: LaunchMode.externalApplication);
      final callbackUri = await deepLinkService.waitForOAuthCallback('gdrive');
      final code = callbackUri.queryParameters['code'];
      final returnedState = callbackUri.queryParameters['state'];
      if (code == null) throw StateError('No authorization code in callback');
      if (returnedState != state) throw StateError('OAuth state mismatch');
      await _handleCodeExchange(code, redirectUri);
      return;
    }

    final result = await OAuthLocalServer.authenticate(
      '$_authBase?response_type=code&client_id=$clientId&redirect_uri=http://localhost'
      '&scope=${Uri.encodeComponent(_scope)}&code_challenge=$codeChallenge&code_challenge_method=S256&state=$state'
      '&access_type=offline&prompt=consent',
    );
    await _handleCodeExchange(result.code, result.redirectUri);
  }

  Future<void> _handleCodeExchange(String code, String redirectUri) async {
    final clientId = SyncConfig.gdriveClientId!;
    final clientSecret = SyncConfig.gdriveClientSecret;
    final data =
        'code=$code&grant_type=authorization_code&client_id=$clientId'
        '&redirect_uri=${Uri.encodeComponent(redirectUri)}'
        '&code_verifier=$_codeVerifier'
        '${clientSecret != null && clientSecret.isNotEmpty ? '&client_secret=$clientSecret' : ''}';
    final response = await _dio.post<Map<String, dynamic>>(
      _tokenUrl,
      options: Options(
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      ),
      data: data,
    );

    final body = response.data!;
    _accessToken = body['access_token'] as String;
    _refreshToken = body['refresh_token'] as String?;
    final expiresIn = body['expires_in'] as int? ?? 3600;
    _expiresAt = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
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
    final clientId = SyncConfig.gdriveClientId!;
    final clientSecret = SyncConfig.gdriveClientSecret;
    final data =
        'grant_type=refresh_token&refresh_token=$_refreshToken&client_id=$clientId'
        '${clientSecret != null && clientSecret.isNotEmpty ? '&client_secret=$clientSecret' : ''}';
    final response = await _dio.post<Map<String, dynamic>>(
      _tokenUrl,
      options: Options(
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      ),
      data: data,
    );
    final body = response.data!;
    _accessToken = body['access_token'] as String;
    final expiresIn = body['expires_in'] as int? ?? 3600;
    _expiresAt = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
  }

  Future<Map<String, dynamic>?> getAccountInfo() async {
    try {
      final token = await getValidToken();
      final response = await _dio.get<Map<String, dynamic>>(
        _userInfoUrl,
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return response.data;
    } catch (_) {
      return null;
    }
  }

  Future<void> disconnect() async {
    if (_accessToken != null) {
      try {
        await _dio.post<void>(
          _revokeUrl,
          queryParameters: {'token': _accessToken},
        );
      } catch (_) {}
    }
    _accessToken = null;
    _refreshToken = null;
    _expiresAt = null;
    _folderId = null;
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
