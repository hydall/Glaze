import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/character_import_persistence_coordinator.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../character_list/character_import_persistence_provider.dart';
import '../../settings/app_settings_provider.dart';
import '../catalog_models.dart';
import '../catalog_provider.dart';
import '../saucepan_account_provider.dart';
import '../services/datacat_provider.dart';
import '../services/saucepan_extractor.dart';
import 'catalog_detail_launcher.dart';

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
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.cs.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _phase != null
                        ? 'Phase: $_phase'
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
            Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
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

    // JanitorAI links open the catalog card instead of extracting from here:
    // the card handles the public-vs-closed decision, the Lorebooks tab, and the
    // toggle-gated local extraction (its Import button). Other hosts keep the
    // DataCat path below.
    if (_isJanitorUrl(url)) {
      await _openJanitorCard(url);
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
          if (mounted) setState(() => _phase = phase);
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

      if (result.charData != null && mounted) {
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
          _error = e.toString();
        });
      }
    }
  }

  bool _isJanitorUrl(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return host == 'janitorai.com' || host.endsWith('.janitorai.com');
  }

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
      _phase = 'extracting locally';
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
          _error = e.toString();
        });
      }
    }
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
      setState(() => _error = 'Could not find a character id in that link.');
      return;
    }
    final item = CatalogItem(id: id, name: '', slug: _janitorSlug(url, id));
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
      builder: (_) => CatalogDetailLauncher(
        item: item,
        provider: CatalogProvider.janitor,
      ),
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
}
