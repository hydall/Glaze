import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/character.dart';
import '../../../core/utils/error_format.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../character_list/character_detail_screen.dart';
import '../../settings/app_settings_provider.dart';
import '../catalog_models.dart';
import '../catalog_provider.dart';
import '../janitor_account_provider.dart';
import '../services/chub_provider.dart';
// `ExtractionResult` here is DataCat's own; the one this file uses is
// JanitorExtractor's, so the DataCat name is hidden to keep it unambiguous.
import '../services/datacat_provider.dart' hide ExtractionResult;
import '../services/janitor_extractor.dart';
import '../services/janitor_provider.dart';
import '../services/janitor_public_lorebook.dart';
import '../services/janitor_webview_proxy.dart';
import '../services/janny_provider.dart';
import 'janitor_login_sheet.dart';
import 'janitor_lorebook_capture_sheet.dart';
import 'janitor_refused_sheet.dart';
import 'janitor_lorebooks_tab.dart';

/// Thrown when a JanitorAI card could be read from neither source because its
/// creator restricted it to logged-in visitors and DataCat has no copy.
class _JanitorLoginRequired implements Exception {
  const _JanitorLoginRequired();
}

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

  /// Set once the user has seen the "proxies are forbidden" sheet and asked for
  /// the public part anyway, so the import that follows skips the capture that
  /// cannot work instead of showing the same sheet again.
  bool _refusalAcknowledged = false;

  /// Progress text for the initial load, set only while the DataCat copy of a
  /// closed JanitorAI card is being fetched — that one can take a while.
  String? _loadPhase;

  /// Raw JanitorAI metadata (only for the janitor provider) — drives the
  /// public-vs-closed decision and the Lorebooks tab.
  Map<String, dynamic>? _janitorMeta;
  bool _definitionPublic = false;

  /// The creator restricted this card to logged-in visitors, we are not one,
  /// and DataCat has no copy either — so there is nothing to preview and the
  /// notice replaces the card.
  bool _loginRequired = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    // A retry starts from scratch: a DataCat miss last time (or a login that
    // has happened since) must not be remembered as settled.
    _datacatTried = false;
    _datacatResult = null;
    try {
      DownloadedCharacter result;
      switch (widget.provider) {
        case CatalogProvider.janitor:
          result = await _fetchJanitorCard();
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
    } on _JanitorLoginRequired {
      if (mounted) setState(() => _loginRequired = true);
    } catch (e) {
      if (mounted) setState(() => _error = formatError(e));
    }
  }

  /// The JanitorAI card, from whichever source "Load character cards with"
  /// points at.
  ///
  /// The card and the metadata are two different things: the metadata
  /// (`/hampter/characters/{id}`, read through the WebView proxy) carries the
  /// lorebook scripts, `allow_proxy` and the public blurb, so it is read on
  /// both paths — best effort in DataCat mode, where a proxy failure must not
  /// cost us a card DataCat can serve anyway.
  Future<DownloadedCharacter> _fetchJanitorCard() async {
    final datacatFirst = _cardSource == ExtractionSource.datacat;
    // The restriction that sent us to DataCat, and the metadata failure we are
    // tolerating — kept apart because only the first one ends in the login
    // notice.
    Object? hidden;
    Object? metaError;

    try {
      await _loadJanitorMeta();
    } catch (e) {
      if (datacatFirst) {
        metaError = e;
      } else if (_janitorRestricted(e) && !_janitorLoggedIn) {
        hidden = e;
      } else {
        rethrow;
      }
    }

    if (datacatFirst || hidden != null) {
      final card = await _datacatCard();
      if (card != null) return card;
      // Hidden from us here AND unknown to DataCat: the card exists, we simply
      // may not see it. Say that instead of an HTTP status.
      if (hidden != null) throw const _JanitorLoginRequired();
    }

    final meta = _janitorMeta;
    // DataCat mode with nothing on either side — surface the proxy's own error.
    if (meta == null) throw metaError ?? const _JanitorLoginRequired();

    final result = janitorCharacterFromMeta(meta);
    // A closed definition leaves the hampter card empty — only the public
    // blurb, no prompt. With character extraction pointed at DataCat nothing
    // local will ever fill it in, so read the card from DataCat's scraped copy.
    if (!_definitionPublic && _characterSource == ExtractionSource.datacat) {
      return await _datacatCard() ?? result;
    }
    return result;
  }

  /// Reads `/hampter/characters/{id}` through the WebView proxy and records what
  /// the rest of the preview needs from it.
  Future<void> _loadJanitorMeta() async {
    final meta = await janitorFetchCharacterMeta(widget.item.id);
    _janitorMeta = meta;
    _definitionPublic = janitorDefinitionPublic(meta);
  }

  /// Whether [e] is JanitorAI saying "not for you" — the card is restricted to
  /// logged-in visitors, or gone. A Cloudflare challenge or a transport failure
  /// is neither, and must not be papered over with a login notice.
  bool _janitorRestricted(Object e) {
    if (e is JanitorAuthException) return true;
    if (e is JanitorCfException) return false;
    final text = e.toString();
    return text.contains('HTTP 401') ||
        text.contains('HTTP 403') ||
        text.contains('HTTP 404');
  }

  bool get _janitorLoggedIn => ref.read(janitorAccountProvider).isLoggedIn;

  /// Whether importing should run the local JanitorAI extraction (proxy capture
  /// + LLM lorebook rebuild) instead of a plain catalog import: only for a
  /// JanitorAI character whose definition is closed, when "Extract characters
  /// with" is set to Local.
  bool get _useLocalExtraction {
    if (widget.provider != CatalogProvider.janitor) return false;
    if (_definitionPublic) return false;
    return _characterSource == ExtractionSource.local;
  }

  AppSettings? get _settings => ref.read(appSettingsProvider).value;

  ExtractionSource get _cardSource =>
      _settings?.janitorCardSource ?? const AppSettings().janitorCardSource;

  ExtractionSource get _characterSource =>
      _settings?.janitorCharacterSource ??
      const AppSettings().janitorCharacterSource;

  ExtractionSource get _lorebookSource =>
      _settings?.janitorLorebookSource ??
      const AppSettings().janitorLorebookSource;

  /// [_datacatCard]'s answer, kept so the two questions it can be asked in one
  /// load ("is the card here at all?" and "does it carry the closed prompt?")
  /// cost one extraction, not two. Cleared by [_fetch] so a retry re-asks.
  DownloadedCharacter? _datacatResult;
  bool _datacatTried = false;

  /// The same JanitorAI character as DataCat has it: DataCat scrapes closed
  /// cards, so its copy carries the prompt the hampter endpoint withholds.
  ///
  /// Best-effort — a card DataCat has never seen is extracted on demand (slow,
  /// hence the phase text), and anything that fails or comes back without a
  /// prompt leaves the hampter card in place rather than making the preview an
  /// error.
  Future<DownloadedCharacter?> _datacatCard() async {
    if (_datacatTried) return _datacatResult;
    _datacatTried = true;
    final url = _sourceUrl();
    if (url == null) return null;
    if (mounted) {
      setState(() => _loadPhase = 'catalog_datacat_card_phase'.tr());
    }
    try {
      final res = await datacatExtractAndPoll(
        url,
        // DataCat reports its own phase names, and sends an empty one between
        // steps — keep the opening line rather than blanking the label.
        onPhaseChange: (p) {
          if (mounted && p.trim().isNotEmpty) setState(() => _loadPhase = p);
        },
      );
      final data = res.charData;
      if (data == null || data.description.trim().isEmpty) return null;
      return _datacatResult = DownloadedCharacter(
        charData: data,
        avatarUrl: res.avatarUrl,
      );
    } catch (e) {
      debugPrint('[catalog] DataCat fallback failed: $e');
      return null;
    } finally {
      if (mounted) setState(() => _loadPhase = null);
    }
  }

  Character _toCharacter(DownloadedCharacter d) {
    final data = d.charData;
    // A closed JanitorAI definition hides the real prompt (it isn't in the
    // public card, only in the blurb which we keep out of the description).
    // Show a hint in the preview's prompt slot instead of a blank field.
    // Display-only: _doImport imports `downloaded` (empty description), not
    // this preview object, so the hint text is never written to the library.
    final janitorClosed =
        widget.provider == CatalogProvider.janitor && !_definitionPublic;
    final description = janitorClosed && data.description.trim().isEmpty
        ? 'catalog_janitor_closed_prompt'.tr()
        : data.description;
    return Character(
      id: 'preview:${widget.item.id}',
      name: data.name.isEmpty ? widget.item.name : data.name,
      description: description,
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

  /// The JanitorAI lorebook context, when this preview has one. Lorebook work
  /// (downloading the public books, capturing and rebuilding the closed one)
  /// runs in the capture sheet, which owns the context choices the automatic
  /// rebuild would have to guess at.
  JanitorLorebookArgs? get _lorebookArgs =>
      widget.provider == CatalogProvider.janitor
          ? JanitorLorebookArgs(
              characterId: widget.item.id,
              sourceUrl: _sourceUrl() ?? widget.item.id,
              meta: _janitorMeta ?? const {},
              definitionPublic: _definitionPublic,
            )
          : null;

  /// Whether the character has any lorebook at all — public, private or
  /// scripted. "Character + lorebooks" hands every one of them to the capture
  /// sheet (nothing is attached silently during the import), so this is the
  /// condition for opening it; a character with no books never does.
  ///
  /// Deliberately the same test the preview uses to decide whether to offer the
  /// "Character + lorebooks" choice at all (`_previewHasLorebooks`): if the
  /// question was asked, the sheet that answers it must open.
  bool get _hasAnyLorebooks => lorebookScriptRefs(_janitorMeta).isNotEmpty;

  /// [skipExtraction] runs the plain catalog import even for a closed JanitorAI
  /// card: the path taken after the user acknowledged that JanitorAI refuses to
  /// assemble this character's prompt and asked for the public part anyway.
  Future<void> _doImport({
    CatalogImportMode mode = CatalogImportMode.character,
    bool skipExtraction = false,
  }) async {
    final downloaded = _downloaded;
    if (downloaded == null || _importing) return;

    // Normally the Import tap already cleared this (see _confirmImportPossible);
    // this is the backstop for a lorebooks-only import reached from elsewhere.
    if (!skipExtraction && !_refusalAcknowledged && _capturesLocally(mode)) {
      final refused = _importRefusal ??
          JanitorWebViewProxy.instance.refusalFor(widget.item.id);
      if (refused != null) {
        final anyway = await showJanitorRefusedSheet(
          context,
          refused,
          // Lorebooks-only imports nothing into the library, so there is no
          // public part left to fall back to.
          offerImportAnyway: mode != CatalogImportMode.lorebooks,
        );
        if (!mounted || !anyway) return;
        return _doImport(mode: mode, skipExtraction: true);
      }
    }

    // Lorebooks only: nothing is added to the character library, so hand
    // straight over to the capture sheet without an import at all.
    final lorebookArgs = _lorebookArgs;
    if (mode == CatalogImportMode.lorebooks) {
      if (lorebookArgs == null) return;
      await showJanitorLorebookCaptureSheet(context, args: lorebookArgs);
      return;
    }

    setState(() {
      _importing = true;
      _importPhase = null;
    });
    try {
      final String importedCharId;
      // Kept so the capture sheet can start from this pass instead of running a
      // second one (see JanitorLorebookCapture.initialExtraction).
      ExtractionResult? extraction;
      // A closed JanitorAI card with the opt-in on: the card itself only exists
      // inside the assembled prompt, so it is captured locally via the proxy.
      // The lorebook is NOT rebuilt here — that is the capture sheet's job below
      // when the user asked for lorebooks too.
      if (_useLocalExtraction && !skipExtraction && !_refusalAcknowledged) {
        final extractor = ref.read(janitorExtractorProvider);
        final result = await extractor.extract(
          _sourceUrl() ?? widget.item.id,
          onPhase: (p) {
            if (mounted) setState(() => _importPhase = p);
          },
        );
        extraction = result;
        // Lorebooks are never attached here, not even the public ones: with
        // "Character + lorebooks" every book — public, private or scripted —
        // is handed to the capture sheet below, so it is the single place they
        // are saved from and nothing lands in the library twice.
        final commit = await extractor.commit(
          result,
          rebuildLorebook: false,
          attachPublicLorebooks: false,
          janitorMeta: _janitorMeta,
          onPhase: (p) {
            if (mounted) setState(() => _importPhase = p);
          },
        );
        importedCharId = commit.glazeCharacterId;
      } else {
        // Public definition: a plain catalog import. Lorebooks stay out of it —
        // the capture sheet below owns all of them (see above).
        importedCharId = await ref
            .read(catalogProvider.notifier)
            .importCharacter(
              downloaded,
              sourceUrl: _sourceUrl(),
              attachLorebooks: false,
              janitorMeta: _janitorMeta,
            );
      }
      if (!mounted) return;
      // Character + lorebooks: the character is in the library, so the lorebook
      // half of the import starts now. The capture sheet opens over the preview,
      // scoped to the character we just imported so its books land on it, and
      // the preview closes once the user is done with it.
      if (mode.importsLorebooks && lorebookArgs != null && _hasAnyLorebooks) {
        await showJanitorLorebookCaptureSheet(
          context,
          args: lorebookArgs,
          characterId: importedCharId,
          initialExtraction: extraction,
        );
        if (!mounted) return;
      }
      Navigator.of(context, rootNavigator: true).pop(importedCharId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      // The account session went stale mid-import. Ask for a fresh login and
      // pick the import back up once it is done.
      if (e is JanitorAuthException) {
        // The session survived neither the refresh nor the retry, so stop
        // claiming an account is signed in while every call to it 401s.
        await ref.read(janitorAccountProvider.notifier).setUserName(null);
        if (!mounted) return;
        final loggedIn = await showJanitorSessionExpiredSheet(context);
        if (mounted && loggedIn) {
          await _doImport(mode: mode, skipExtraction: skipExtraction);
        }
        return;
      }
      // A refusal is JanitorAI's policy, not a failure to retry: explain it and
      // offer the public part instead of an error dialog.
      if (e is JanitorRefusedException) {
        final anyway = await showJanitorRefusedSheet(context, e);
        if (mounted && anyway) {
          await _doImport(mode: mode, skipExtraction: true);
        }
        return;
      }
      GlazeErrorDialog.show(context, e, prefix: 'Import failed: ');
    }
  }

  /// Whether [mode] would run the local JanitorAI capture — the step a refusal
  /// makes impossible.
  bool _capturesLocally(CatalogImportMode mode) =>
      mode == CatalogImportMode.lorebooks
          ? widget.provider == CatalogProvider.janitor &&
                _lorebookSource == ExtractionSource.local
          : _useLocalExtraction;

  /// The refusal standing in the way of a capture-backed import, if any: the
  /// character's own metadata (`allow_proxy: false`), or a refusal JanitorAI
  /// returned earlier this session for a reason the metadata does not carry
  /// (a ban, a limit).
  JanitorRefusedException? get _importRefusal {
    if (!_useLocalExtraction || _refusalAcknowledged) return null;
    if (!janitorAllowsProxy(_janitorMeta)) {
      return const JanitorRefusedException.proxyForbidden();
    }
    return JanitorWebViewProxy.instance.refusalFor(widget.item.id);
  }

  /// The action on the "logged-in visitors only" notice: log in, then read the
  /// card again — this time as someone allowed to see it. Also the way back for
  /// a user who logs in and finds DataCat had a copy after all.
  Future<void> _loginAndRetry() async {
    await openJanitorAccountSheet(context, ref);
    if (!mounted) return;
    setState(() {
      _loginRequired = false;
      _error = null;
    });
    await _fetch();
  }

  /// Runs on the Import tap, before the mode is chosen: a character JanitorAI
  /// will not assemble a prompt for cannot be recovered at all, so say that
  /// first rather than after the user has picked what to pull. Returns whether
  /// the import should go ahead.
  Future<bool> _confirmImportPossible() async {
    final refusal = _importRefusal;
    if (refusal == null) return true;
    final anyway = await showJanitorRefusedSheet(context, refusal);
    if (!mounted || !anyway) return false;
    setState(() => _refusalAcknowledged = true);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (_loginRequired) {
      return _ErrorView(
        icon: Icons.lock_outline_rounded,
        message: 'catalog_janitor_login_required'.tr(),
        actionLabel: 'catalog_janitor_login_required_btn'.tr(),
        onRetry: _loginAndRetry,
      );
    }
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: () {
        setState(() => _error = null);
        _fetch();
      });
    }
    final downloaded = _downloaded;
    if (downloaded == null) {
      return _LoadingView(phase: _loadPhase);
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
      janitorLorebookArgs: _lorebookArgs,
      onImport: _doImport,
      onBeforeImport: _confirmImportPossible,
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
  /// What the wait is for, when it is long enough to need saying (the DataCat
  /// card fetch). Null renders the bare spinner.
  final String? phase;

  const _LoadingView({this.phase});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 360,
      decoration: BoxDecoration(
        color: context.cs.surfaceContainerHighest,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlazeSpinner(color: context.cs.primary),
            if (phase != null) ...[
              const SizedBox(height: 12),
              Text(
                phase!,
                style: TextStyle(
                  fontSize: 12,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The card that could not be shown, and the one thing to do about it. Doubles
/// as the "visible to logged-in visitors only" notice, which is not a failure
/// to retry but a login to make — hence the icon and the action label.
class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final IconData icon;
  final String? actionLabel;

  const _ErrorView({
    required this.message,
    required this.onRetry,
    this.icon = Icons.error_outline_rounded,
    this.actionLabel,
  });

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
          Icon(icon, size: 48, color: context.cs.onSurfaceVariant),
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
              child: Text(
                actionLabel ?? 'Retry',
                style: const TextStyle(
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
