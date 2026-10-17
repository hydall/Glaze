import 'dart:convert';

/// Everything a backup leaves out when the user exports without API keys:
/// provider keys, catalog account tokens and the cloud sync OAuth tokens.
///
/// A backup is the file people attach to a bug report, so by default it must
/// not hand anyone access to their providers or their Dropbox / Google Drive.
/// On import the gaps are filled back from the device, so restoring a keyless
/// backup over an existing install keeps the keys it already had.
abstract final class BackupSecrets {
  /// The export switch, remembered between exports. Off unless the user
  /// turned it on.
  static const includeApiKeysPrefKey = 'gz_backup_include_api_keys';

  /// Manifest field telling the importer whether the archive carries keys.
  /// Absent in archives that predate the switch — those always had them.
  static const manifestFlag = 'apiKeysIncluded';

  /// Preferences that hold nothing but a credential. They are left out of the
  /// archive entirely; the importer only writes keys the archive has, so the
  /// device's own values survive a restore.
  static const prefKeys = {
    'gz_sync_tokens',
    'gz_chub_api_key',
    'gz_dc_device',
    'gz_dc_token',
    'gz_dc_user_token',
    'gz_saucepan_token',
    'gz_janny_token',
    'gz_embedding_key',
    'gz_imggen_api_key',
    'gz_imggen_naistera_api_key',
    'gz_imggen_routmy_api_key',
  };

  /// Credential columns per table. They are exported as null.
  static const tableColumns = {
    'api_configs': ['api_key', 'embedding_api_key'],
  };

  static const _secretFieldNames = {
    'accesstoken',
    'refreshtoken',
    'idtoken',
    'authtoken',
    'sessiontoken',
    'usertoken',
    'devicetoken',
    'token',
    'password',
    'secret',
    'clientsecret',
  };

  /// Whether a JSON field holds a credential: `apiKey`, `generationApiKey`,
  /// `routmyApiKey`, `refresh_token`... Matched on the whole name, so
  /// `maxTokens`, `tokenizer` or a lorebook entry's `keys` stay untouched.
  static bool isSecretField(String name) {
    final n = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return n.endsWith('apikey') || _secretFieldNames.contains(n);
  }

  /// [row] with the credential columns of [tableName] nulled.
  static Map<String, Object?> stripRow(
    String tableName,
    Map<String, Object?> row,
  ) {
    final columns = tableColumns[tableName];
    if (columns == null) return row;
    return {
      ...row,
      for (final c in columns)
        if (row.containsKey(c)) c: null,
    };
  }

  /// Preferences without credentials: [prefKeys] dropped, and secret fields
  /// blanked inside every value that is a JSON document (pipeline settings,
  /// image generation profiles and the like).
  static Map<String, dynamic> stripPrefs(Map<String, dynamic> prefs) {
    final out = <String, dynamic>{};
    for (final entry in prefs.entries) {
      if (prefKeys.contains(entry.key)) continue;
      final value = entry.value;
      if (value is String) {
        out[entry.key] = _mapJsonString(value, _strip);
      } else if (value is List) {
        out[entry.key] = value
            .map((e) => e is String ? _mapJsonString(e, _strip) : e)
            .toList();
      } else {
        out[entry.key] = value;
      }
    }
    return out;
  }

  /// The value a preference should take when a keyless backup is restored:
  /// [backup] with every secret field it blanked taken back from [local].
  static Object? refillPref(Object? backup, Object? local) {
    if (backup is String && local is String) {
      final localJson = _tryDecode(local);
      if (localJson == null) return backup;
      return _mapJsonString(backup, (b) => _refill(b, localJson));
    }
    return backup;
  }

  static Object? _strip(Object? value) {
    if (value is Map) {
      return {
        for (final e in value.entries)
          e.key: e.key is String && isSecretField(e.key as String)
              ? (e.value is String ? '' : null)
              : _strip(e.value),
      };
    }
    if (value is List) return value.map(_strip).toList();
    return value;
  }

  static Object? _refill(Object? backup, Object? local) {
    if (backup is Map && local is Map) {
      return {
        for (final e in backup.entries)
          e.key: e.key is String && isSecretField(e.key as String)
              ? (_isBlank(e.value) && local[e.key] != null
                    ? local[e.key]
                    : e.value)
              : _refill(e.value, local[e.key]),
      };
    }
    if (backup is List && local is List) {
      return [
        for (var i = 0; i < backup.length; i++)
          _refill(backup[i], i < local.length ? local[i] : null),
      ];
    }
    return backup;
  }

  static bool _isBlank(Object? v) => v == null || (v is String && v.isEmpty);

  /// Applies [transform] to [raw] if it is a JSON object or array; any other
  /// string is returned as-is. Unchanged documents keep their original text.
  static String _mapJsonString(
    String raw,
    Object? Function(Object?) transform,
  ) {
    final decoded = _tryDecode(raw);
    if (decoded == null) return raw;
    final encoded = jsonEncode(transform(decoded));
    return encoded == jsonEncode(decoded) ? raw : encoded;
  }

  static Object? _tryDecode(String raw) {
    final s = raw.trimLeft();
    if (!s.startsWith('{') && !s.startsWith('[')) return null;
    try {
      final v = jsonDecode(s);
      return v is Map || v is List ? v : null;
    } catch (_) {
      return null;
    }
  }
}
