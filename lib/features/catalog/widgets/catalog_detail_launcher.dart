import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/character.dart';
import '../../../core/utils/error_format.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../character_list/character_detail_screen.dart';
import '../../settings/app_settings_provider.dart';
import '../catalog_models.dart';
import '../catalog_provider.dart';
import '../services/chub_provider.dart';
import '../services/datacat_provider.dart';
import '../services/janitor_extractor.dart';
import '../services/janitor_provider.dart';
import '../services/janny_provider.dart';
import 'janitor_lorebooks_tab.dart';

/// Fetches a catalog item's full character data and presents
/// `CharacterDetailScreen` in preview mode (Import FAB, no destructive
/// actions).
class CatalogDetailLauncher extends ConsumerStatefulWidget {
  final CatalogItem item;
  final CatalogProvider provider;

  const CatalogDetailLauncher({
    super.key,
    required this.item,
    required this.provider,
  });

  @override
  ConsumerState<CatalogDetailLauncher> createState() =>
      _CatalogDetailLauncherState();
}

class _CatalogDetailLauncherState
    extends ConsumerState<CatalogDetailLauncher> {
  DownloadedCharacter? _downloaded;
  String? _error;
  bool _importing = false;
  String? _importPhase;

  /// Raw JanitorAI metadata (only for the janitor provider) — drives the
  /// public-vs-closed decision and the Lorebooks tab.
  Map<String, dynamic>? _janitorMeta;
  bool _definitionPublic = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      DownloadedCharacter result;
      switch (widget.provider) {
        case CatalogProvider.janitor:
          // Always read the card from /hampter so the catalog card carries the
          // public info. If the definition is public we use it verbatim; if it
          // is closed we still show what we have (the closed card/lorebook can
          // then be extracted locally — see _doImport / the Lorebooks tab).
          final meta = await janitorFetchCharacterMeta(widget.item.id);
          _janitorMeta = meta;
          _definitionPublic = janitorDefinitionPublic(meta);
          result = janitorCharacterFromMeta(meta);
        case CatalogProvider.janny:
          result = await jannyFetchCharacter(widget.item.id, widget.item.slug);
        case CatalogProvider.datacat:
          result = await datacatGetCharacter(widget.item.id);
        case CatalogProvider.chub:
          result = await chubGetCharacter(
            widget.item.fullPath ?? widget.item.id,
          );
      }
      if (mounted) setState(() => _downloaded = result);
    } catch (e) {
      if (mounted) setState(() => _error = formatError(e));
    }
  }

  /// Whether importing should run the local JanitorAI extraction (proxy capture
  /// + LLM lorebook rebuild) instead of a plain catalog import: only for a
  /// JanitorAI character whose definition is closed, when the user opted in.
  bool get _useLocalExtraction {
    if (widget.provider != CatalogProvider.janitor) return false;
    if (_definitionPublic) return false;
    final settings = ref.read(appSettingsProvider).value;
    return settings?.extractJanitorLocally ?? false;
  }

  Character _toCharacter(DownloadedCharacter d) {
    final data = d.charData;
    return Character(
      id: 'preview:${widget.item.id}',
      name: data.name.isEmpty ? widget.item.name : data.name,
      description: data.description,
      personality: data.personality,
      scenario: data.scenario,
      firstMes: data.firstMes,
      mesExample: data.mesExample,
      systemPrompt: data.systemPrompt,
      postHistoryInstructions: data.postHistoryInstructions,
      creator:
          data.creator.isEmpty ? widget.item.creator : data.creator,
      creatorNotes: data.creatorNotes,
      tags: data.tags.isEmpty ? widget.item.tags : data.tags,
      alternateGreetings: data.alternateGreetings,
    );
  }

  Future<void> _doImport({bool includeLorebooks = false}) async {
    final downloaded = _downloaded;
    if (downloaded == null || _importing) return;
    setState(() {
      _importing = true;
      _importPhase = null;
    });
    try {
      final String importedCharId;
      if (_useLocalExtraction) {
        // Closed JanitorAI card + opt-in: capture the hidden card and closed
        // lorebook locally via the proxy, then rebuild the lorebook with the
        // active LLM (a lorebook failure still keeps the character).
        final extractor = ref.read(janitorExtractorProvider);
        final result = await extractor.extract(
          _sourceUrl() ?? widget.item.id,
          onPhase: (p) {
            if (mounted) setState(() => _importPhase = p);
          },
        );
        final commit = await extractor.commit(
          result,
          onPhase: (p) {
            if (mounted) setState(() => _importPhase = p);
          },
        );
        importedCharId = commit.glazeCharacterId;
        if (mounted && commit.lorebookError != null) {
          GlazeErrorDialog.show(
            context,
            'Character imported, but the closed lorebook could not be rebuilt: '
            '${commit.lorebookError}',
          );
        }
      } else {
        if (includeLorebooks && mounted) {
          setState(() => _importPhase = 'catalog_import_lorebooks_phase'.tr());
        }
        importedCharId = await ref
            .read(catalogProvider.notifier)
            .importCharacter(
              downloaded,
              sourceUrl: _sourceUrl(),
              attachLorebooks: includeLorebooks,
              janitorMeta: _janitorMeta,
            );
      }
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(importedCharId);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _importing = false);
        GlazeErrorDialog.show(context, e, prefix: 'Import failed: ');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: () {
        setState(() => _error = null);
        _fetch();
      });
    }
    final downloaded = _downloaded;
    if (downloaded == null) {
      return const _LoadingView();
    }
    final char = _toCharacter(downloaded);
    final avatarUrl =
        downloaded.avatarUrl ?? widget.item.avatarUrl;
    return CharacterDetailScreen(
      charId: char.id,
      previewCharacter: char,
      previewAvatarUrl: avatarUrl,
      previewSourceUrl: _sourceUrl(),
      previewAuthorUrl: _authorUrl(),
      // Only JanitorAI exposes a comments/reviews endpoint keyed by character id.
      janitorReviewCharId: widget.provider == CatalogProvider.janitor
          ? widget.item.id
          : null,
      // JanitorAI previews get a Lorebooks tab (public + closed lorebooks).
      janitorLorebookArgs: widget.provider == CatalogProvider.janitor
          ? JanitorLorebookArgs(
              characterId: widget.item.id,
              sourceUrl: _sourceUrl() ?? widget.item.id,
              meta: _janitorMeta ?? const {},
              definitionPublic: _definitionPublic,
            )
          : null,
      onImport: _doImport,
      importing: _importing,
      importPhase: _importPhase,
    );
  }

  /// External URL of the character's page on its source site. Only Janitor
  /// exposes a stable per-character web URL today; other providers return null
  /// (the "open in browser" button is then hidden).
  String? _sourceUrl() {
    if (widget.provider != CatalogProvider.janitor) return null;
    final id = widget.item.id;
    if (id.isEmpty) return null;
    final slug = widget.item.slug;
    if (slug != null && slug.isNotEmpty && slug != id) {
      return 'https://janitorai.com/characters/${id}_$slug';
    }
    return 'https://janitorai.com/characters/$id';
  }

  /// External URL of the creator's profile page on its source site.
  String? _authorUrl() {
    if (widget.provider != CatalogProvider.janitor) return null;
    final creatorId = widget.item.creatorId;
    if (creatorId == null || creatorId.isEmpty) return null;
    return 'https://janitorai.com/profiles/$creatorId';
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 360,
      decoration: BoxDecoration(
        color: context.cs.surfaceContainerHighest,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Center(
        child: CircularProgressIndicator(color: context.cs.primary),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 360,
      decoration: BoxDecoration(
        color: context.cs.surfaceContainerHighest,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 48,
            color: context.cs.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(
              color: context.cs.onSurfaceVariant,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: onRetry,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: context.cs.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Retry',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
