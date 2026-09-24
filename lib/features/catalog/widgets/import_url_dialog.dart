import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/character_import_persistence_coordinator.dart';
import '../../../core/utils/error_format.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_error_block.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../character_list/character_import_persistence_provider.dart';
import '../../settings/app_settings_provider.dart';
import '../catalog_models.dart';
import '../catalog_provider.dart';
import '../saucepan_account_provider.dart';
import '../services/datacat_provider.dart';
import '../services/extraction_status.dart';
import '../services/saucepan_extractor.dart';
import 'catalog_detail_launcher.dart';
import 'datacat_phase_label.dart';

class ImportUrlDialog extends ConsumerStatefulWidget {
  const ImportUrlDialog({super.key});

  @override
  ConsumerState<ImportUrlDialog> createState() => _ImportUrlDialogState();
}

class _ImportUrlDialogState extends ConsumerState<ImportUrlDialog> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _phase;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              'placeholder_janitor_url'.tr(),
              style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 14),
            ),
          ),
          TextField(
            controller: _controller,
            autofocus: true,
            style: TextStyle(fontSize: 14, color: context.cs.onSurface),
            decoration: InputDecoration(
              hintText: 'https://...',
              hintStyle: TextStyle(
                color: context.cs.onSurfaceVariant,
                fontSize: 14,
              ),
              filled: true,
              fillColor: context.cs.surface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
            enabled: !_loading,
            onSubmitted: (_) => _startExtraction(),
          ),
          if (_loading) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: GlazeSpinner(color: context.cs.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _phase != null
                        ? 'catalog_phase_label'.tr(
                            namedArgs: {'phase': _phase!},
                          )
                        : 'catalog_extracting'.tr(),
                    style: TextStyle(
                      color: context.cs.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            GlazeErrorBlock(message: _error!),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _loading ? null : _startExtraction,
              style: ElevatedButton.styleFrom(
                backgroundColor: context.cs.primary,
                foregroundColor: context.cs.onPrimary,
              ),
              child: Text(
                _loading
                    ? 'catalog_importing'.tr()
                    : 'action_import_by_link'.tr(),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startExtraction() async {
    final url = _controller.text.trim();
    if (url.isEmpty) return;

    // Catalog-hosted links open the catalog card instead of extracting from
    // here: the card handles the public-vs-closed decision, the Lorebooks tab,
    // and the toggle-gated local extraction (its Import button). Other hosts
    // keep the DataCat path below.
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (_isJanitorHost(host)) {
      await _openJanitorCard(url);
      return;
    }
    if (_isJannyHost(host)) {
      await _openJannyCard(url);
      return;
    }
    if (_isChubHost(host)) {
      await _openChubCard(url);
      return;
    }

    // These sources have no browsable catalog countertab in Glaze: their URL
    // is resolved with a source-specific fetch and imported straight into the
    // library, no preview sheet.
    if (_isPygmalionHost(host)) {
      await _importPygmalion(url);
      return;
    }
    if (_isRisuHost(host)) {
      await _importRisu(url);
      return;
    }
    if (_isPerchanceHost(host)) {
      await _importPerchance(url);
      return;
    }
    if (_isAiccHost(host)) {
      await _importAicc(url);
      return;
    }

    // Saucepan companion links extract LOCALLY (on-device fragment reassembly)
    // when the user has configured a Saucepan token; otherwise they fall through
    // to the remote DataCat path below.
    if (_isSaucepanCompanionUrl(url) &&
        ref.read(saucepanAccountProvider).isLoggedIn) {
      await _extractSaucepanLocal(url);
      return;
    }

    // Probe the link before the remote extractor: if it directly serves a card
    // file — a PNG with embedded data or a character JSON — import it on-device.
    // We decide by what the URL actually returns, not by its path shape, so
    // extensionless download endpoints (e.g. `…/download/png/69682`) work too.
    // Anything else falls through to DataCat below.
    if (await _tryImportDirectFile(url)) return;

    setState(() {
      _loading = true;
      _error = null;
      _phase = null;
    });

    try {
      final result = await datacatExtractAndPoll(
        url,
        onPhaseChange: (phase) {
          if (mounted) setState(() => _phase = datacatPhaseLabel(phase));
        },
      );

      if (result.error != null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = result.error;
          });
        }
        return;
      }

      if (result.charData == null) {
        // Neither a character nor an error. Nothing should reach here, and that
        // is the point: the branch that did not exist is the branch that left
        // the spinner turning with no timeout behind it at all.
        if (mounted) {
          setState(() {
            _loading = false;
            _error = extractionFinishedEmptyMessage(isSaucepan: false);
          });
        }
        return;
      }

      if (mounted) {
        final notifier = ref.read(catalogProvider.notifier);
        final downloaded = DownloadedCharacter(
          charData: result.charData!,
          avatarUrl: result.avatarUrl,
        );
        await notifier.importCharacter(downloaded, sourceUrl: url);
        if (mounted) {
          Navigator.pop(context);
          GlazeToast.show(context, 'Imported ${result.charData!.name}');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = formatError(e);
        });
      }
    }
  }

  bool _isJanitorHost(String host) =>
      host == 'janitorai.com' || host.endsWith('.janitorai.com');

  bool _isJannyHost(String host) =>
      host == 'jannyai.com' || host.endsWith('.jannyai.com');

  bool _isChubHost(String host) =>
      host == 'chub.ai' ||
      host.endsWith('.chub.ai') ||
      host == 'characterhub.org' ||
      host.endsWith('.characterhub.org');

  bool _isPygmalionHost(String host) =>
      host == 'pygmalion.chat' || host.endsWith('.pygmalion.chat');

  bool _isRisuHost(String host) =>
      host == 'realm.risuai.net' || host.endsWith('.risuai.net');

  bool _isPerchanceHost(String host) =>
      host == 'perchance.org' || host.endsWith('.perchance.org');

  bool _isAiccHost(String host) =>
      host == 'aicharactercards.com' ||
      host.endsWith('.aicharactercards.com');

  bool _isSaucepanCompanionUrl(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    final isHost = host == 'saucepan.ai' || host.endsWith('.saucepan.ai');
    return isHost && parseCompanionId(url) != null;
  }

  /// Extracts a Saucepan companion on-device (no browser) and imports it. Used
  /// only when a Saucepan token is configured — otherwise the remote DataCat
  /// path handles saucepan.ai links.
  Future<void> _extractSaucepanLocal(String url) async {
    setState(() {
      _loading = true;
      _error = null;
      _phase = 'catalog_extracting_locally'.tr();
    });
    try {
      final result =
          await ref.read(saucepanExtractorProvider).extractCompanion(url);
      if (!mounted) return;
      await ref
          .read(catalogProvider.notifier)
          .importCharacter(result.character, sourceUrl: url);
      if (mounted) {
        Navigator.pop(context);
        GlazeToast.show(
            context, 'Imported ${result.character.charData.name}');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = formatError(e);
        });
      }
    }
  }

  // ── Source-specific URL import (no catalog card) ─────────────────────────
  //
  // Sources Glaze does not browse: the URL is resolved with a source-specific
  // fetch and the character goes straight into the library, no preview sheet.

  static const _pygmalionApi =
      'https://server.pygmalion.chat/api/export/character/';
  static const _risuApi = 'https://realm.risuai.net/api/v1/download/png-v3/';
  static const _aiccApi =
      'https://aicharactercards.com/wp-json/pngapi/v1/image/';
  static const _perchanceApi = 'https://user.uploads.dev/file/';

  /// Pygmalion export: `…/api/export/character/{uuid}/v2` returns a V2 card
  /// whose `data.avatar` is the portrait URL.
  Future<void> _importPygmalion(String url) async {
    final id = _uuidRe.firstMatch(url)?.group(0);
    if (id == null) {
      setState(() => _error = 'error_character_id_not_found'.tr());
      return;
    }
    await _runProviderImport(() async {
      final jsonData = await _downloadJson('$_pygmalionApi$id/v2');
      final character = jsonData['character'];
      if (character is! Map) {
        throw const FormatException('Pygmalion returned no character');
      }
      final card = character.cast<String, dynamic>();
      final data = card['data'] is Map
          ? (card['data'] as Map).cast<String, dynamic>()
          : card;
      final avatar = data['avatar'];
      await _importCharacterData(
        _characterDataFromV2(data),
        avatarUrl: avatar is String && avatar.isNotEmpty ? avatar : null,
      );
    });
  }

  /// RisuAI's download endpoint serves a PNG card with the JSON embedded.
  Future<void> _importRisu(String url) async {
    final id = _risuId(url);
    if (id == null) {
      setState(() => _error = 'error_character_id_not_found'.tr());
      return;
    }
    await _runProviderImport(() async {
      final bytes = await _downloadBytes('$_risuApi$id?non_commercial=true');
      await _importCardBytes(bytes, 'card.png');
    });
  }

  /// AICharacterCards serves the card PNG at
  /// `/wp-json/pngapi/v1/image/{author}/{character}`.
  Future<void> _importAicc(String url) async {
    final path = _aiccPath(url);
    if (path == null) {
      setState(() => _error = 'error_character_id_not_found'.tr());
      return;
    }
    await _runProviderImport(() async {
      final bytes = await _downloadBytes('$_aiccApi$path');
      await _importCardBytes(bytes, 'card.png');
    });
  }

  /// Perchance serves a gzipped character blob; the V2 card is assembled from
  /// its fields (mirrors SillyTavern's `downloadPerchanceCharacter`).
  Future<void> _importPerchance(String url) async {
    final slug = _perchanceSlug(url);
    if (slug == null) {
      setState(() => _error = 'error_character_id_not_found'.tr());
      return;
    }
    await _runProviderImport(() async {
      final gz = await _downloadBytes(
        '$_perchanceApi$slug',
        headers: const {'User-Agent': 'Glaze'},
      );
      final parsed = jsonDecode(utf8.decode(gzip.decode(gz)));
      final character = parsed is Map ? parsed['addCharacter'] : null;
      if (character is! Map) {
        throw const FormatException('Perchance returned no character');
      }
      final pc = character.cast<String, dynamic>();
      final name = (pc['name'] ?? '').toString().trim();

      // The avatar is either a `data:image/...` URL (saved as bytes) or a real
      // URL the catalog importer downloads for us.
      final avatar = pc['avatar'];
      final avatarUrl = avatar is Map ? avatar['url'] as String? : null;
      List<int>? avatarBytes;
      String? resolvedAvatarUrl;
      if (avatarUrl != null && avatarUrl.startsWith('data:image/')) {
        final comma = avatarUrl.indexOf(',');
        if (comma > 0) {
          avatarBytes = base64Decode(avatarUrl.substring(comma + 1));
        }
      } else {
        resolvedAvatarUrl = avatarUrl;
      }

      await _importCharacterData(
        CharacterData(
          name: name.isEmpty ? 'Unnamed Perchance Character' : name,
          description: (pc['roleInstruction'] ?? '') as String,
          personality: (pc['reminderMessage'] ?? '') as String,
          creator: (pc['metaTitle'] ?? '') as String,
          creatorNotes: (pc['metaDescription'] ?? '') as String,
        ),
        avatarUrl: resolvedAvatarUrl,
        avatarBytes: avatarBytes,
      );
    });
  }

  /// Runs a no-preview import with the shared loading/error UI around [body].
  /// On success [body] closes the dialog; on failure the error is shown.
  Future<void> _runProviderImport(Future<void> Function() body) async {
    setState(() {
      _loading = true;
      _error = null;
      _phase = 'catalog_extracting_locally'.tr();
    });
    try {
      await body();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = formatError(e);
        });
      }
    }
  }

  /// Imports a PNG/JSON card file through the same on-device importer the file
  /// picker uses, then persists it (character, lorebook, gallery).
  Future<void> _importCardBytes(Uint8List bytes, String fileName) async {
    final importer = await ref.read(characterImporterProvider.future);
    final result = await importer.importFromBytes(bytes, fileName);
    if (!mounted) return;
    final persisted = await ref
        .read(characterImportPersistenceCoordinatorProvider)
        .persist(result);
    if (persisted case CharacterImportPersistenceFailure()) {
      persisted.rethrowError();
    }
    if (mounted) {
      Navigator.pop(context);
      GlazeToast.show(context, 'Imported ${result.character.name}');
    }
  }

  /// Imports structured card data (a source whose JSON we normalize ourselves)
  /// and closes the dialog on success.
  Future<void> _importCharacterData(
    CharacterData data, {
    String? avatarUrl,
    List<int>? avatarBytes,
  }) async {
    await ref.read(catalogProvider.notifier).importCharacter(
          DownloadedCharacter(
            charData: data,
            avatarUrl: avatarUrl,
            avatarBytes: avatarBytes,
          ),
        );
    if (mounted) {
      Navigator.pop(context);
      GlazeToast.show(context, 'Imported ${data.name}');
    }
  }

  /// Maps a Character Card V2 `data` block onto [CharacterData].
  CharacterData _characterDataFromV2(Map<String, dynamic> data) {
    String s(dynamic v) => v == null ? '' : v.toString();
    List<String> list(dynamic v) =>
        v is List ? v.map((e) => e.toString()).toList() : const [];
    return CharacterData(
      name: s(data['name']).isEmpty ? 'Unknown' : s(data['name']),
      description: s(data['description']),
      personality: s(data['personality']),
      scenario: s(data['scenario']),
      firstMes: s(data['first_mes']),
      mesExample: s(data['mes_example']),
      creatorNotes: s(data['creator_notes']),
      systemPrompt: s(data['system_prompt']),
      postHistoryInstructions: s(data['post_history_instructions']),
      alternateGreetings: list(data['alternate_greetings']),
      tags: list(data['tags']),
      creator: s(data['creator']),
      creatorId: s(data['creator_id']),
      characterBook: data['character_book'],
    );
  }

  Future<Uint8List> _downloadBytes(
    String url, {
    Map<String, String>? headers,
  }) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    final res = await dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: headers,
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );
    return Uint8List.fromList(res.data ?? const []);
  }

  Future<Map<String, dynamic>> _downloadJson(String url) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    final res = await dio.get<dynamic>(
      url,
      options: Options(
        responseType: ResponseType.json,
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );
    final data = res.data;
    if (data is Map) return data.cast<String, dynamic>();
    throw const FormatException('Unexpected response from source');
  }

  /// Id from a RisuAI `…/character/{id}` URL. Risu ids are hex strings, not
  /// necessarily dashed UUIDs, so the path segment is read as-is.
  String? _risuId(String url) {
    final segments =
        Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).toList() ??
            const [];
    final i = segments.indexOf('character');
    if (i < 0 || i + 1 >= segments.length) return null;
    final id = segments[i + 1];
    return id.isEmpty ? null : id;
  }

  /// `author/character` from an AICharacterCards URL (last two path segments).
  String? _aiccPath(String url) {
    final segments =
        Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).toList() ??
            const [];
    if (segments.length < 2) return null;
    return '${segments[segments.length - 2]}/${segments.last}';
  }

  /// Gzipped file slug from a Perchance `?data=Name~{slug}.gz` URL.
  String? _perchanceSlug(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final source = uri.queryParameters['data'] ?? url;
    final idx = source.indexOf('~');
    if (idx < 0 || idx + 1 >= source.length) return null;
    final slug = source.substring(idx + 1).split('&').first;
    return slug.isEmpty ? null : slug;
  }

  /// PNG file signature — first 8 bytes of every PNG.
  static const _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  bool _looksLikePng(Uint8List bytes) {
    if (bytes.length < _pngMagic.length) return false;
    for (var i = 0; i < _pngMagic.length; i++) {
      if (bytes[i] != _pngMagic[i]) return false;
    }
    return true;
  }

  /// True when [bytes] decode to a character-card JSON object (has `name`,
  /// nested `data`, or a `chara_card_v*` spec). Guards against importing random
  /// JSON API responses that happen to sit behind a link.
  bool _looksLikeCardJson(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return false;
      final spec = decoded['spec'];
      return decoded.containsKey('name') ||
          decoded.containsKey('data') ||
          spec == 'chara_card_v2' ||
          spec == 'chara_card_v3';
    } catch (_) {
      return false;
    }
  }

  /// Downloads [url] and, if it directly serves a card file (a PNG with embedded
  /// data or a character JSON), imports it locally through [CharacterImporter] —
  /// persisting the character, its lorebook, and any embedded gallery images,
  /// mirroring the local file-pick flow.
  ///
  /// Returns `true` when the link was handled here; `false` when it isn't a
  /// direct card file (unreachable, empty, or unrecognized content) so the
  /// caller can fall back to the remote extractor.
  Future<bool> _tryImportDirectFile(String url) async {
    setState(() {
      _loading = true;
      _error = null;
      _phase = 'checking link';
    });

    Uint8List bytes;
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
      ));
      final res = await dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
      );
      bytes = Uint8List.fromList(res.data ?? const []);
    } catch (_) {
      // Not fetchable as a raw file — let the remote extractor try instead.
      return false;
    }

    if (bytes.isEmpty) return false;

    // Decide by content, not by the URL: a PNG signature means an embedded-card
    // PNG; otherwise the only other on-device format we import directly is a
    // character JSON. Anything else falls back to the extractor.
    final isPng = _looksLikePng(bytes);
    if (!isPng && !_looksLikeCardJson(bytes)) return false;

    try {
      final importer = await ref.read(characterImporterProvider.future);
      final result = await importer.importFromBytes(
        bytes,
        isPng ? 'card.png' : 'card.json',
      );
      if (!mounted) return true;

      final persisted = await ref
          .read(characterImportPersistenceCoordinatorProvider)
          .persist(result);
      if (persisted case CharacterImportPersistenceFailure()) {
        persisted.rethrowError();
      }

      if (mounted) {
        Navigator.pop(context);
        GlazeToast.show(context, 'Imported ${result.character.name}');
      }
      return true;
    } catch (e) {
      // Looked like a card but couldn't be parsed as one (e.g. a plain image or
      // unrelated JSON) — fall back to the remote extractor rather than
      // surfacing a low-level parse error.
      debugPrint('[import_url_dialog] direct import failed, falling back: $e');
      return false;
    }
  }

  static final _uuidRe = RegExp(
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
    caseSensitive: false,
  );

  String? _janitorCharacterId(String url) => _uuidRe.firstMatch(url)?.group(0);

  /// Slug suffix from a `…/characters/{id}_{slug}` URL, if present.
  String? _janitorSlug(String url, String id) {
    final idx = url.indexOf(id);
    if (idx < 0) return null;
    final after = url.substring(idx + id.length);
    final m = RegExp(r'^_([^/?#]+)').firstMatch(after);
    return m?.group(1);
  }

  /// Closes this dialog and opens the JanitorAI catalog card for the pasted
  /// link, mirroring a tap in the catalog grid (preview + Import FAB + Lorebooks
  /// tab). The card itself decides whether to import directly (public) or run a
  /// local extraction (closed + toggle on).
  Future<void> _openJanitorCard(String url) async {
    final id = _janitorCharacterId(url);
    if (id == null) {
      setState(() => _error = 'error_character_id_not_found'.tr());
      return;
    }
    await _openCatalogCard(
      CatalogItem(id: id, name: '', slug: _janitorSlug(url, id)),
      CatalogProvider.janitor,
    );
  }

  /// Opens the JannyAI catalog card for a `…/characters/{id}_{slug}` link.
  Future<void> _openJannyCard(String url) async {
    final parsed = _jannyRef(url);
    if (parsed == null) {
      setState(() => _error = 'error_character_id_not_found'.tr());
      return;
    }
    await _openCatalogCard(
      CatalogItem(id: parsed.$1, name: '', slug: parsed.$2, source: 'janny'),
      CatalogProvider.janny,
    );
  }

  /// Opens the Chub catalog card for a `…/characters/{creator}/{name}` link.
  /// Lorebook links are not a catalog card, so they fall through.
  Future<void> _openChubCard(String url) async {
    final fullPath = _chubFullPath(url);
    if (fullPath == null) {
      setState(() => _error = 'error_character_id_not_found'.tr());
      return;
    }
    await _openCatalogCard(
      CatalogItem(id: fullPath, name: '', fullPath: fullPath, source: 'chub'),
      CatalogProvider.chub,
    );
  }

  /// Closes this dialog and opens the catalog card for [item], mirroring a tap
  /// in the catalog grid (preview + Import FAB + provider-specific tabs). The
  /// card itself decides how to fetch and import the character.
  Future<void> _openCatalogCard(
    CatalogItem item,
    CatalogProvider provider,
  ) async {
    // The root navigator's context outlives this dialog, so the card sheet and
    // any post-import navigation keep a valid context after we pop.
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    final openCard =
        ref.read(appSettingsProvider).value?.openCardAfterImport ?? true;
    Navigator.pop(context);

    final importedCharId = await showModalBottomSheet<String>(
      context: rootContext,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CatalogDetailLauncher(item: item, provider: provider),
    );
    if (!rootContext.mounted ||
        importedCharId == null ||
        importedCharId.isEmpty) {
      return;
    }
    GlazeToast.show(rootContext, 'Imported');
    if (!openCard) return;
    rootContext.go(
      '/characters?open=${Uri.encodeQueryComponent(importedCharId)}',
    );
  }

  /// Character id and optional slug from a JannyAI `…/characters/{id}_{slug}`
  /// URL. The id is whatever precedes the first `_`; JannyAI ids are not UUIDs.
  (String, String?)? _jannyRef(String url) {
    final segments =
        Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).toList() ??
            const [];
    final ci = segments.indexOf('characters');
    if (ci < 0 || ci + 1 >= segments.length) return null;
    final last = segments[ci + 1];
    final idx = last.indexOf('_');
    if (idx <= 0) return (last, null);
    final id = last.substring(0, idx);
    final slug = last.substring(idx + 1);
    if (id.isEmpty) return null;
    return (id, slug.isEmpty ? null : slug);
  }

  /// `creator/name` from a Chub/CharacterHub `…/characters/{creator}/{name}`
  /// URL. Null for lorebook links, which have no catalog card.
  String? _chubFullPath(String url) {
    final segments =
        Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).toList() ??
            const [];
    if (segments.isEmpty) return null;
    final ci = segments.indexOf('characters');
    if (ci < 0) {
      // A `…/lorebooks/{creator}/{name}` link is not a character card.
      if (segments.contains('lorebooks')) return null;
      return segments.length >= 2
          ? '${segments[segments.length - 2]}/${segments.last}'
          : null;
    }
    if (segments.length < ci + 3) return null;
    return '${segments[ci + 1]}/${segments[ci + 2]}';
  }
}
