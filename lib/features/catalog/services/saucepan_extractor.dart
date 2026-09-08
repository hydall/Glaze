import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../catalog_models.dart';

/// Native (on-device) Saucepan (saucepan.ai) companion extraction — a Dart port
/// of JAR's `saucepan.js`.
///
/// Unlike the JanitorAI path, Saucepan needs no browser: the companion
/// definition is available directly from the authenticated REST API. The catch
/// is that definitions ship as a **shuffled** list of text fragments padded with
/// **decoy** fragments — a naive join is garbled. Each real fragment carries a
/// `proof` hash the decoys fail; reassembly validates the proof, orders the
/// survivors by `key ^ mask`, and concatenates. Ported so the output matches
/// JAR (and Saucepan's own web client) byte-for-byte.
///
/// Data comes from two endpoints (both auth-gated by a Saucepan bearer token):
///   GET /api/v1/companion/definition?companion_id=ID → named prose sections
///   GET /api/v2/companions/ID                         → metadata + body
///                                                        fragments + greetings

const String _saucepanBase = 'https://saucepan.ai';
const String _saucepanUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
const String _tokenPrefsKey = 'gz_saucepan_token';

// ─── Fragment reassembly (verbatim port of Saucepan's client scheme) ─────────
// 32-bit unsigned integer math throughout: `& 0xFFFFFFFF` emulates JS `>>> 0`
// and `Math.imul(...) >>> 0` (the 56-bit product fits Dart's 64-bit int).

const int _fnvOffset = 2166136261;
const int _fnvPrime = 16777619;

int _rotl(int value, int bits) =>
    ((value << bits) | (value >>> (32 - bits))) & 0xFFFFFFFF;

int _fragmentHash(int mask, int derivedKey, String text) {
  final bytes = utf8.encode(text);
  var h = (_fnvOffset ^ _rotl(mask, 7) ^ _rotl(derivedKey, 13)) & 0xFFFFFFFF;
  for (final b in bytes) {
    h ^= b;
    h = (h * _fnvPrime) & 0xFFFFFFFF;
  }
  return h & 0xFFFFFFFF;
}

int _u32(dynamic v) => v is num ? v.toInt() & 0xFFFFFFFF : 0;

/// Reassembles a `{fragments, mask}` content object into prose, dropping decoys.
/// Real fragments are those whose `proof` matches `_fragmentHash(mask, key^mask,
/// text)`; survivors are ordered by `key ^ mask` and concatenated.
String assembleFragments(dynamic content) {
  if (content is! Map) return '';
  final rawFragments = content['fragments'];
  if (rawFragments is! List) return '';
  final mask = _u32(content['mask']);

  final kept = <MapEntry<int, String>>[];
  for (final f in rawFragments) {
    if (f is! Map) continue;
    final text = f['text'];
    if (text is! String) continue;
    final key = _u32(f['key']);
    final derivedKey = (key ^ mask) & 0xFFFFFFFF;
    if (_fragmentHash(mask, derivedKey, text) == _u32(f['proof'])) {
      kept.add(MapEntry(derivedKey, text));
    }
  }
  kept.sort((a, b) => a.key - b.key);
  return kept.map((e) => e.value).join();
}

/// Extracts the companion UUID from a `saucepan.ai/companion/<id>` URL.
String? parseCompanionId(String url) {
  final m = RegExp(r'saucepan\.ai/companion/([a-f0-9-]{8,64})',
          caseSensitive: false)
      .firstMatch(url);
  return m?.group(1);
}

/// Thrown on any Saucepan extraction failure; [status] mirrors JAR's error
/// codes (401 = not logged in, 400 = bad URL, 502 = upstream).
class SaucepanException implements Exception {
  final String message;
  final int status;
  SaucepanException(this.message, {this.status = 0});
  @override
  String toString() => message;
}

/// The result of a companion extraction: the recovered character and its id.
class SaucepanExtraction {
  final String companionId;
  final DownloadedCharacter character;
  const SaucepanExtraction({required this.companionId, required this.character});
}

/// REST client for Saucepan: holds the bearer token (persisted in
/// SharedPreferences), logs in, and extracts companions.
class SaucepanExtractor {
  SaucepanExtractor();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.plain,
    // Accept a 4xx without throwing so we can read the error body ourselves.
    validateStatus: (_) => true,
  ));

  String _token = '';

  bool get isLoggedIn => _token.trim().isNotEmpty;

  Map<String, String> _headers({bool withAuth = false}) => {
        'User-Agent': _saucepanUa,
        'Accept': '*/*',
        'Origin': _saucepanBase,
        'Referer': '$_saucepanBase/',
        'x-saucepan-client-version': '1',
        if (withAuth && isLoggedIn) 'Authorization': 'Bearer $_token',
      };

  /// Loads the persisted token (call once on boot / before use).
  Future<void> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenPrefsKey) ?? '';
  }

  /// Sets and persists the bearer token directly (for users who paste one).
  Future<void> setToken(String token) async {
    _token = token.trim();
    final prefs = await SharedPreferences.getInstance();
    if (_token.isEmpty) {
      await prefs.remove(_tokenPrefsKey);
    } else {
      await prefs.setString(_tokenPrefsKey, _token);
    }
  }

  /// Clears the stored session.
  Future<void> logout() => setToken('');

  /// Logs in with handle + password, storing the returned bearer token.
  Future<void> login(String handle, String password) async {
    final res = await _dio.post<String>(
      '$_saucepanBase/api/v1/auth/sign_in_password',
      data: jsonEncode({'handle': handle.trim(), 'password': password}),
      options: Options(headers: {
        ..._headers(),
        'Content-Type': 'application/json',
        'Referer': '$_saucepanBase/sign-in',
      }),
    );
    final data = _tryJson(res.data);
    if ((res.statusCode ?? 0) >= 400) {
      final msg = (data?['error'] is Map ? data!['error']['message'] : null)
              ?.toString() ??
          'Saucepan HTTP ${res.statusCode}';
      throw SaucepanException(msg, status: res.statusCode ?? 0);
    }
    final t = (data?['token'] ??
            data?['access_token'] ??
            data?['session_token'] ??
            data?['sessionToken'])
        ?.toString();
    if (t == null || t.isEmpty) {
      throw SaucepanException('login succeeded but no token was returned');
    }
    await setToken(t);
  }

  Future<({int status, Map<String, dynamic>? data})> _getJson(
    String path, {
    bool withAuth = false,
  }) async {
    final res = await _dio.get<String>(
      '$_saucepanBase$path',
      options: Options(headers: _headers(withAuth: withAuth)),
    );
    return (status: res.statusCode ?? 0, data: _tryJson(res.data));
  }

  /// Fetches a Saucepan companion by URL and builds a [DownloadedCharacter].
  /// Requires a stored token (definition + scenarios are auth-gated).
  Future<SaucepanExtraction> extractCompanion(String url) async {
    // The extractor may be used before its async token-load finished (fresh app
    // start); pull the persisted token in before deciding we're logged out.
    if (_token.isEmpty) await loadToken();
    if (!isLoggedIn) {
      throw SaucepanException('No Saucepan token configured — log in first.',
          status: 401);
    }
    final companionId = parseCompanionId(url);
    if (companionId == null) {
      throw SaucepanException('Not a Saucepan companion URL.', status: 400);
    }

    final results = await Future.wait([
      _getJson('/api/v1/companion/definition?companion_id=$companionId',
          withAuth: true),
      _getJson('/api/v2/companions/$companionId', withAuth: true),
    ]);
    final defRes = results[0];
    final compRes = results[1];

    if (defRes.status >= 400 || defRes.data == null) {
      final msg = (defRes.data?['error'] is Map
                  ? defRes.data!['error']['message']
                  : null)
              ?.toString() ??
          'Saucepan HTTP ${defRes.status}';
      throw SaucepanException(msg, status: defRes.status == 401 ? 401 : 502);
    }

    // Named prose sections from the definition endpoint.
    final sections = <String, String>{};
    final rawSections = defRes.data!['sections'];
    if (rawSections is List) {
      for (final s in rawSections) {
        if (s is Map && s['title'] is String && s['content'] != null) {
          sections[s['title'] as String] = assembleFragments(s['content']);
        }
      }
    }

    final companion = compRes.data?['companion'];
    final comp = companion is Map ? companion : const <String, dynamic>{};
    if (compRes.status >= 400 || companion is! Map) {
      debugPrint('[saucepan] greetings/metadata unavailable '
          '(companions/$companionId HTTP ${compRes.status})');
    }

    // Body: prefer the definition's "Companion Core", fall back to the v2 body.
    var description = sections['Companion Core'] ?? '';
    if (description.isEmpty && comp['full_description_fragments'] != null) {
      description = assembleFragments(comp['full_description_fragments']);
    }

    // Greetings live only on the v2 companion as starting scenarios.
    final greetings = <String>[];
    final scenarios = comp['starting_scenarios_fragments'];
    if (scenarios is List) {
      for (final sc in scenarios) {
        final text =
            sc is Map ? assembleFragments(sc['message']) : '';
        if (text.trim().isNotEmpty) greetings.add(text);
      }
    }

    // Advanced Prompt / Response Formatting have no dedicated V2 field — keep
    // them (labeled) in creator notes so nothing authored is silently dropped.
    final notesParts = <String>[];
    final shortDesc = (comp['short_description'] ?? '').toString().trim();
    if (shortDesc.isNotEmpty) notesParts.add(shortDesc);
    if ((sections['Advanced Prompt'] ?? '').isNotEmpty) {
      notesParts.add('--- Advanced Prompt ---\n${sections['Advanced Prompt']}');
    }
    if ((sections['Response Formatting Instructions'] ?? '').isNotEmpty) {
      notesParts.add(
          '--- Response Formatting ---\n${sections['Response Formatting Instructions']}');
    }

    final imageId = comp['image'] is Map ? comp['image']['id'] : null;
    final avatarUrl = imageId != null
        ? '$_saucepanBase/cdn/${Uri.encodeComponent(imageId.toString())}/card'
        : null;

    final character = DownloadedCharacter(
      charData: CharacterData(
        name: (comp['display_name'] ?? comp['name'] ?? 'Unknown').toString(),
        description: description,
        firstMes: greetings.isNotEmpty ? greetings.first : '',
        alternateGreetings:
            greetings.length > 1 ? greetings.sublist(1) : const [],
        mesExample: sections['Example Dialogue'] ?? '',
        creatorNotes: notesParts.join('\n\n'),
        tags: comp['tags'] is List
            ? (comp['tags'] as List).map((e) => e.toString()).toList()
            : const [],
      ),
      avatarUrl: avatarUrl,
    );

    return SaucepanExtraction(companionId: companionId, character: character);
  }

  static Map<String, dynamic>? _tryJson(String? body) {
    if (body == null || body.isEmpty) return null;
    try {
      final v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }
}

/// Singleton-ish provider for the Saucepan extractor (holds the loaded token).
final saucepanExtractorProvider = Provider<SaucepanExtractor>((ref) {
  final extractor = SaucepanExtractor();
  // Best-effort token load; callers can await [SaucepanExtractor.loadToken] too.
  extractor.loadToken();
  return extractor;
});
