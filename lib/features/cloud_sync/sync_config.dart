import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';

class SyncConfig {
  static String? _dropboxAppKey;
  static String? _dropboxAppSecret;
  static String? _gdriveClientId;
  static String? _gdriveClientSecret;
  static String? _gdriveIosClientId;

  static Future<void> load() async {
    if (!dotenv.isInitialized) {
      await dotenv.load(fileName: '.env');
    }
    _dropboxAppKey = dotenv.env['DROPBOX_APP_KEY'];
    _dropboxAppSecret = dotenv.env['DROPBOX_APP_SECRET'];
    _gdriveClientId = dotenv.env['GDRIVE_CLIENT_ID'];
    _gdriveClientSecret = dotenv.env['GDRIVE_CLIENT_SECRET'];
    _gdriveIosClientId = dotenv.env['GDRIVE_IOS_CLIENT_ID'];
  }

  static String? get dropboxAppKey => _dropboxAppKey;
  static String? get dropboxAppSecret => _dropboxAppSecret;
  static String get dropboxRedirectNative => 'com.hydall.glaze://oauth/dropbox';
  static String? get gdriveClientId => _gdriveClientId;
  static String? get gdriveClientSecret => _gdriveClientSecret;
  static String? get gdriveIosClientId => _gdriveIosClientId;
  static String get gdriveRedirectNative {
    if (Platform.isIOS && _gdriveIosClientId != null) {
      return 'com.googleusercontent.apps.${_gdriveIosClientId!.split('-').first}:/oauth2redirect';
    }
    return 'com.hydall.glaze://oauth/gdrive';
  }

  static bool canStartSyncAuth(String provider) {
    switch (provider) {
      case 'dropbox':
        return _dropboxAppKey != null && _dropboxAppKey!.isNotEmpty;
      case 'gdrive':
        return _gdriveClientId != null && _gdriveClientId!.isNotEmpty;
      default:
        return false;
    }
  }

  static bool hasAnySyncProviderConfigured() =>
      canStartSyncAuth('dropbox') || canStartSyncAuth('gdrive');
}
