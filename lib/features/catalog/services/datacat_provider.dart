import 'dart:math';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'greeting_normalizer.dart';
import 'catalog_http.dart';
import '../catalog_models.dart';
import 'extraction_status.dart';

/// URL extraction: asking DataCat to go and index a character it has never
/// seen, then reading what came out.
///
/// Everything else DataCat is used for — browsing, search, tags, creators,
/// community, and the card/image transfer — now runs on the official Client
/// API under `services/datacat/`. This file is what could not move: the Client
/// API is read-mostly over DataCat's existing index, and has no endpoint that
/// takes a URL and produces a new row. So the undocumented site endpoints, the
/// anonymous session token they need, and the source-shaped row reader below
/// stay, scoped to the one job that still requires them.
///
/// Two features depend on it: importing a character by pasting its URL, and
/// recovering a JanitorAI card whose definition its creator closed (DataCat
/// scrapes those, and the public endpoint does not serve them).

const _base = 'https://datacat.run';
const _keyDevice = 'gz_dc_device';
const _keyToken = 'gz_dc_token';
const _saucepanCdnBase = 'https://cdn.saucepan.ai';
const _imageBase = 'https://ella.janitorai.com/bot-avatars/';

String _uuid() {
  final r = Random();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replaceAllMapped(
    RegExp('[xy]'),
    (m) {
      final v = r.nextInt(16);
      return (m.group(0) == 'x' ? v : (v & 0x3 | 0x8)).toRadixString(16);
    },
  );
}

Future<String> _getDeviceToken() async {
  final prefs = await SharedPreferences.getInstance();
  var token = prefs.getString(_keyDevice);
  if (token == null) {
    token = _uuid();
    await prefs.setString(_keyDevice, token);
  }
  return token;
}

Future<String?> _getSessionToken() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_keyToken);
}

Future<void> _setSessionToken(String token) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_keyToken, token);
}

Map<String, String> _authHeaders(String token) => {
      'X-Session-Token': token,
      'Origin': 'https://datacat.run',
      'Referer': 'https://datacat.run/',
    };

Future<String> datacatInit() async {
  final deviceToken = await _getDeviceToken();
  final data = await catalogPost(
    '$_base/api/liberator/identify',
    {'deviceToken': deviceToken},
    {
      'Origin': 'https://datacat.run',
      'Referer': 'https://datacat.run/',
    },
  );
  final sessionToken = data['sessionToken'] as String?;
  if (sessionToken == null) throw Exception('DataCat: no sessionToken');
  await _setSessionToken(sessionToken);
  return sessionToken;
}

Future<String> _getToken() async {
  var token = await _getSessionToken();
  token ??= await datacatInit();
  return token;
}

/// Runs an authenticated DataCat call, re-establishing the session once when
/// the server rejects the token it was made with.
///
/// The anonymous session token comes from `/api/liberator/identify` and is kept
/// in SharedPreferences with no expiry, so it outlives whatever the server is
/// still willing to honour. A token DataCat has forgotten answers 401/403 to
/// every call carrying it, and the browse path used to be the only one that
/// knew how to replace one — it ran a throwaway probe request before each
/// search purely to find out. Every other endpoint dead-ended: the card detail
/// showed `HTTP 403: Forbidden` behind a Retry button that re-sent the same
/// dead token, which is why retrying never helped.
///
/// A 403 can also be DataCat's bot protection, which no amount of fresh
/// sessions will cure. One retry is what tells the two apart — and the wasted
/// request only happens on a failure that was already fatal.
Future<T> _datacatAuthed<T>(Future<T> Function(String token) call) async {
  final token = await _getToken();
  try {
    return await call(token);
  } on DioException catch (e) {
    final status = catalogErrorStatus(e);
    if (status != 401 && status != 403) rethrow;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyToken);
    return await call(await datacatInit());
  }
}

Future<Map<String, dynamic>> _datacatGet(String path) =>
    _datacatAuthed((token) => catalogGet('$_base$path', _authHeaders(token)));

Future<Map<String, dynamic>> _datacatPost(
  String path,
  Map<String, dynamic> body,
) => _datacatAuthed(
  (token) => catalogPost('$_base$path', body, _authHeaders(token)),
);

String? _pickAvatarSource(Map<String, dynamic> raw, Map<String, dynamic> meta) {
  return (raw['avatar'] ?? raw['image'] ?? raw['image_url'] ??
          raw['avatar_url'] ?? raw['max_res_url'] ?? meta['image'] ??
          meta['image_url'] ?? meta['avatar'] ?? meta['avatar_url']) as String?;
}

String? _resolveAvatarUrl(String? url) {
  if (url == null) return null;
  if (url.startsWith('http')) return url;
  if (url.startsWith('//')) return 'https:$url';
  if (url.startsWith('/images/')) return '$_saucepanCdnBase$url';
  if (url.startsWith('images/')) return '$_saucepanCdnBase/$url';
  if (RegExp(r'^[0-9a-f-]+/highres$', caseSensitive: false).hasMatch(url)) {
    return '$_saucepanCdnBase/images/$url';
  }
  if (url.startsWith('/')) return 'https://ella.janitorai.com$url';
  if (!url.contains('/')) return '$_imageBase$url';
  return 'https://ella.janitorai.com/$url';
}

/// The active, non-placeholder primary content variant of a DataCat row. For
/// Saucepan cards with a hidden definition, DataCat's "Character Repair" job
/// exposes the recovered body here (with `description` overloaded to carry it).
Map<String, dynamic>? _pickRecoveryVariant(Map<String, dynamic> char) {
  final variants = char['content_variants'];
  if (variants is! List) return null;
  for (final v in variants) {
    if (v is Map && v['isPrimary'] == true && v['isRecoveryPlaceholder'] != true) {
      final content = v['content'];
      if (content is Map) return content.cast<String, dynamic>();
    }
  }
  return null;
}

/// Recovery-sourced `chara_card_v2_json` bodies carry edge
/// `##DESCRIPTION START##`-style delimiter lines; strip them.
String _stripDatacatMarkers(String text) {
  if (text.isEmpty) return text;
  return text
      .replaceFirst(RegExp(r'^\s*##[A-Z _]*(?:START|END)##[ \t]*\r?\n?'), '')
      .replaceFirst(RegExp(r'\r?\n?[ \t]*##[A-Z _]*(?:START|END)##\s*$'), '')
      .trim();
}

/// Maps a DataCat `/api/characters/{id}` row into a [CharacterData].
///
/// Field placement is source-dependent, ported from `buildV2FromDatacat` in the
/// SillyTavern-CharacterLibrary reference. For JanitorAI-source rows the real
/// definition is in `personality` and the website blurb (often HTML) is in
/// `description`; Saucepan rows overload `description` / recovery variants. We
/// keep the definition in [CharacterData.description] and the blurb in
/// [CharacterData.creatorNotes] — the same placement `buildV2FromDatacat` uses
/// (definition into `data.description`, `data.personality` left empty), so
/// `{{description}}` resolves to the prompt body and the blurb never lands in
/// it.
///
/// Only extraction results go through this. A character the Client API can
/// serve arrives as a standard Character Card V2 and is read by
/// `datacat/datacat_cards.dart`, which needs none of this guesswork.
///
/// Public so the field mapping can be tested against a row rather than
/// only through a live request: which greeting field a row carries is
/// exactly what #98 turned on.
CharacterData datacatCharacterData(Map<String, dynamic> char) {
  String s(dynamic v) => v == null ? '' : v.toString();
  String pick(List<String> xs) =>
      xs.firstWhere((e) => e.trim().isNotEmpty, orElse: () => '');

  final isSaucepan = char['primary_content_source_kind'] == 'saucepan';
  final recovered = _pickRecoveryVariant(char);
  final v2Data = (char['chara_card_v2_json'] is Map &&
          (char['chara_card_v2_json'] as Map)['data'] is Map)
      ? ((char['chara_card_v2_json'] as Map)['data'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  final companion = (char['companion_snapshot'] is Map)
      ? (char['companion_snapshot'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};

  final definition = isSaucepan
      ? pick([
          s(recovered?['description']), s(recovered?['personality']),
          s(v2Data['description']), s(char['description']),
        ])
      : pick([
          s(char['personality']), s(recovered?['personality']),
          _stripDatacatMarkers(s(v2Data['description'])),
        ]);
  final scenario =
      pick([s(char['scenario']), s(recovered?['scenario']), s(v2Data['scenario'])]);
  final creatorNotes = isSaucepan
      ? pick([s(companion['full_description']), s(v2Data['creator_notes'])])
      : pick([s(char['description']), s(v2Data['creator_notes'])]);

  // Multiple first messages ("alternate greetings"). The top-level field is
  // often an empty [] while the real list lives in chara_card_v2_json; pick the
  // first NON-EMPTY list rather than the first non-null (mirrors the reference).
  final altG = [
    char['alternate_greetings'],
    recovered?['alternate_greetings'],
    v2Data['alternate_greetings'],
  ].firstWhere(
    (a) => a is List && a.isNotEmpty,
    orElse: () => const <dynamic>[],
  );
  // Every greeting the row carries, folded into an opening line plus
  // alternates. `first_messages` is Janitor's plural field and DataCat mirrors
  // Janitor rows, so a card can arrive with its whole set there and nothing in
  // the singular field; reading only the singular one left slot one blank and
  // shifted every greeting down by one, which is the "datacat skips the 1st
  // greeting" in the report.
  final greetings = normalizeGreetings(
    primary: pick([
      s(char['first_message']),
      s(recovered?['first_message']),
      s(v2Data['first_mes']),
    ]),
    others: [
      ...greetingList(char['first_messages']),
      ...greetingList(recovered?['first_messages']),
      ...greetingList(v2Data['first_messages']),
      ...greetingList(altG),
    ],
  );

  final name = pick([s(char['chat_name']), s(char['chatName']), s(char['name'])]);

  return CharacterData(
    name: name.isEmpty ? 'Unknown' : name,
    description: definition,
    personality: '',
    scenario: scenario,
    firstMes: greetings.firstMes,
    mesExample:
        pick([s(char['example_dialogs']), s(char['mes_example']), s(v2Data['mes_example'])]),
    creatorNotes: creatorNotes,
    systemPrompt: s(v2Data['system_prompt']),
    postHistoryInstructions: s(v2Data['post_history_instructions']),
    alternateGreetings: greetings.alternates,
    tags: const [],
    creator: pick([s(char['creator_name']), s(char['creatorName'])]),
    creatorId: pick([s(char['creator_id']), s(char['creatorId'])]),
    characterBook: v2Data['character_book'],
  );
}

/// Reads the row an extraction produced.
///
/// Deliberately the plain character endpoint, NOT `/download`: `/download` is
/// gated behind a Cloudflare Turnstile lease and answers 403. The Client API
/// makes that lease obtainable and is the supported path for a character it
/// already knows — but a row this session just created is read here, in the
/// same session that created it.
Future<DownloadedCharacter> datacatGetCharacter(String uuid) async {
  final ts = DateTime.now().millisecondsSinceEpoch;
  final data = await _datacatGet('/api/characters/$uuid?t=$ts&sourceKind=janitor');
  final char = (data['character'] ?? data) as Map<String, dynamic>;
  return DownloadedCharacter(
    charData: datacatCharacterData(char),
    avatarUrl: _resolveAvatarUrl(_pickAvatarSource(char, {})),
  );
}

String _detectExtractionSource(String url) {
  if (RegExp(r'^https?://(?:www\.)?saucepan\.ai/companion/', caseSensitive: false).hasMatch(url)) {
    return 'saucepan';
  }
  return 'janitor';
}

Future<Map<String, dynamic>> _datacatExtract(String url, {bool publicFeed = true}) async {
  final idempotencyKey = _uuid();
  final source = _detectExtractionSource(url);

  if (source == 'saucepan') {
    return _datacatPost(
      '/api/saucepan-extract/run',
      {
        'companion': url,
        'extractHidden': false,
        'includeSearch': true,
        'alwaysReextract': false,
        'netnsRole': 'general_scraper',
        'sourceKind': 'one_off',
        'sourceRef': idempotencyKey,
        'vpnNamespace': 'general_scraper',
        'idempotencyKey': idempotencyKey,
      },
    );
  }

  return _datacatPost(
    '/api/character/smart-extract-v2',
    {
      'url': url,
      'appearOnPublicFeed': publicFeed,
      'useSeparateWorkerServer': true,
      'inlinePostExtractCreatorProfile': true,
      'idempotencyKey': idempotencyKey,
    },
  );
}

Future<Map<String, dynamic>> _datacatExtractionStatus() =>
    _datacatGet('/api/extraction/status?t=${DateTime.now().millisecondsSinceEpoch}');

Future<String?> datacatGetCharacterAvatar(String uuid) async {
  final ts = DateTime.now().millisecondsSinceEpoch;
  final data = await _datacatGet('/api/characters/$uuid?t=$ts');
  final char = (data['character'] ?? data) as Map<String, dynamic>;
  final meta = (data['metadata'] ?? <String, dynamic>{}) as Map<String, dynamic>;
  return _resolveAvatarUrl(_pickAvatarSource(char, meta));
}

class ExtractionResult {
  final CharacterData? charData;
  final String? avatarUrl;
  final String? characterId;
  final String? error;
  final String? phase;

  ExtractionResult({this.charData, this.avatarUrl, this.characterId, this.error, this.phase});
}

Future<ExtractionResult> datacatExtractAndPoll(
  String url, {
  void Function(String phase)? onPhaseChange,
}) async {
  try {
    final extractRes = await _datacatExtract(url);

    if (extractRes['characterId'] != null) {
      final charId = extractRes['characterId'] as String;
      final result = await datacatGetCharacter(charId);
      return ExtractionResult(
        charData: result.charData,
        avatarUrl: result.avatarUrl,
        characterId: charId,
      );
    }

    final myRequestId = extractRes['requestId'] as String?;
    final preStatus = await _datacatExtractionStatus();
    final prevRunId = (preStatus['run']?['requestId'] ?? '') as String;
    final uuidMatch = RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', caseSensitive: false)
        .firstMatch(url);
    final targetUuid = uuidMatch?.group(0);

    const maxAttempts = 60;
    // A run reported as finished-but-empty has to be seen twice before the
    // import gives up on it. The status endpoint composes the run and the
    // character it produced from different places, so a single poll can catch
    // the moment in between; three more seconds is a cheap price for not
    // calling a successful import a failure.
    var emptyReadings = 0;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 3));

      try {
        final status = await _datacatExtractionStatus();
        final reading = readExtractionStatus(
          status,
          requestId: myRequestId,
          previousRunId: prevRunId,
          targetUuid: targetUuid,
        );
        onPhaseChange?.call(reading.phase);

        final characterId = reading.characterId;
        if (characterId != null) {
          final result = await datacatGetCharacter(characterId);
          String? avatarUrl = result.avatarUrl;
          if (avatarUrl == null && _detectExtractionSource(url) == 'saucepan') {
            avatarUrl = await datacatGetCharacterAvatar(characterId);
          }
          return ExtractionResult(
            charData: result.charData,
            avatarUrl: avatarUrl,
            characterId: characterId,
          );
        }

        if (reading.state == ExtractionRunState.finishedEmpty) {
          if (++emptyReadings >= 2) {
            return ExtractionResult(
              error: extractionFinishedEmptyMessage(
                isSaucepan: _detectExtractionSource(url) == 'saucepan',
              ),
            );
          }
        } else {
          emptyReadings = 0;
        }
      } catch (_) {}
    }

    return ExtractionResult(error: 'Extraction timed out');
  } catch (e) {
    return ExtractionResult(error: e.toString());
  }
}
