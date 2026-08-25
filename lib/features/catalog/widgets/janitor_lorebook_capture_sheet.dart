import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/tokenizer.dart';
import '../../../core/models/lorebook.dart';
import '../../../core/services/file_export_service.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../core/utils/error_format.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_block.dart';
import '../../../shared/widgets/help_tip.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../settings/app_settings_provider.dart';
import '../janitor_account_provider.dart';
import '../services/catalog_error_labels.dart';
import '../services/janitor_extractor.dart';
import '../services/janitor_lorebook_rebuilder.dart';
import '../services/janitor_provider.dart';
import '../services/janitor_public_lorebook.dart';
import '../services/janitor_separate.dart';
import '../services/janitor_webview_proxy.dart';
import 'janitor_build_widgets.dart';
import 'janitor_extraction_settings_sheet.dart';
import 'janitor_lorebooks_tab.dart';

/// Glossary term the help tip beside the sheet title opens.
const String _kHelpTermExtraction = 'janitor-extraction';

/// The three stages of the closed-lorebook flow, named in the sheet header so
/// it is always clear which one is on screen and how far the flow goes.
enum _Phase { collect, build, save }

extension _PhaseLabel on _Phase {
  String get label => switch (this) {
    _Phase.collect => 'catalog_lorebooks_phase_collect'.tr(),
    _Phase.build => 'catalog_lorebooks_phase_build'.tr(),
    _Phase.save => 'catalog_lorebooks_phase_save'.tr(),
  };
}

/// Opens the lorebook capture sheet for a JanitorAI character.
///
/// This is where the import flow sends the user when they pick "Lorebooks" or
/// "Character + lorebooks": the catalog preview's Lorebooks tab only *lists*
/// what the character has, and every action — download a public book, capture
/// and rebuild the closed one — happens here.
///
/// [characterId] is the Glaze character the saved books are scoped to; null
/// saves them as standalone (global) lorebooks.
Future<void> showJanitorLorebookCaptureSheet(
  BuildContext context, {
  required JanitorLorebookArgs args,
  String? characterId,
  ExtractionResult? initialExtraction,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (_) => JanitorLorebookCapture(
      args: args,
      characterId: characterId,
      initialExtraction: initialExtraction,
    ),
  );
}

/// The JanitorAI lorebook capture + build UI — a Flutter port of JAR's
/// `#tabLorebook`.
///
/// - **Public lorebooks** attached to the character are downloaded whole
///   (`/hampter/script/{id}`) and can be saved to Glaze or exported as a
///   SillyTavern World Info `.json`.
/// - **Closed lorebooks** are recovered by capturing the assembled prompt via
///   the proxy ([JanitorExtractor.extract]) and rebuilt into structured entries
///   with the active LLM ([JanitorExtractor.buildLorebook]).
///
/// Two separate context selections drive that, exactly as in JAR:
/// *extraction context* (`exSources`) picks what is sent **into the JanitorAI
/// chat** to make entries fire, and *key-inference context* (`useSources`)
/// picks what the build LLM may read to infer trigger keys. The second one only
/// appears once entries have actually been collected — until then there is
/// nothing to build.
class JanitorLorebookCapture extends ConsumerStatefulWidget {
  final JanitorLorebookArgs args;

  /// Glaze character the saved books are attached to. Null → saved globally.
  final String? characterId;

  /// A capture the caller already ran (the import flow captures the hidden card
  /// through the same pass). When set, the sheet starts from it instead of
  /// driving a second capture — one extraction mutates the JanitorAI account
  /// (preset, generation settings, a chat, a persona), so repeating it for the
  /// same character in the same flow is churn the user pays for twice.
  final ExtractionResult? initialExtraction;

  const JanitorLorebookCapture({
    super.key,
    required this.args,
    this.characterId,
    this.initialExtraction,
  });

  @override
  ConsumerState<JanitorLorebookCapture> createState() =>
      _JanitorLorebookCaptureState();
}

/// A selection of context blocks, used for both the extraction trigger and the
/// build LLM's key inference. Defaults are JAR's: name-dense, cheap sources on,
/// the bulky ones opt-in.
class _ContextSources {
  bool card = true;
  bool catalog = true;
  bool scenario = true;
  bool greetings = false;
  bool extra = false;

  /// The one default that differs between the two selections — see the fields
  /// it is constructed for.
  bool lorebookDescs;

  _ContextSources({this.lorebookDescs = false});

  void copyFrom(_ContextSources other) {
    card = other.card;
    catalog = other.catalog;
    scenario = other.scenario;
    greetings = other.greetings;
    lorebookDescs = other.lorebookDescs;
    extra = other.extra;
  }
}

class _JanitorLorebookCaptureState
    extends ConsumerState<JanitorLorebookCapture> {
  // Public lorebooks.
  bool _loadingPublic = true;
  List<PublicLorebook> _public = const [];

  // Closed-lorebook extraction.
  bool _extracting = false;
  String? _extractPhase;
  LabeledError? _extractError;
  ExtractionResult? _extraction;

  /// What is stuffed into the message sent into the JanitorAI chat to make the
  /// closed lorebook fire (JAR's `exSources`).
  final _extractSources = _ContextSources();
  final _extractExtraController = TextEditingController();

  /// What the build LLM may read to infer trigger keys (JAR's `useSources`).
  /// Lorebook descriptions are on by default here — they are a summary of the
  /// very entries being keyed, which is worth reading but a poor trigger.
  final _buildSources = _ContextSources(lorebookDescs: true);
  final _buildExtraController = TextEditingController();

  /// Key-inference context derivable from the catalog metadata alone, so the
  /// sources can be previewed and chosen before the capture runs. Computed once
  /// — the metadata does not change while the sheet is open.
  late final _previewCtx = ref
      .read(janitorExtractorProvider)
      .contextFromMeta(widget.args.meta);
  final _nameController = TextEditingController();
  bool _building = false;
  LabeledError? _buildError;
  LorebookBuildException? _buildDebug;
  Lorebook? _built;
  Timer? _timer;
  int _elapsed = 0;

  /// The character's **closed** lorebooks: attached books that couldn't be
  /// downloaded whole (private, or an inaccessible advanced script). These are
  /// recovered by capturing the assembled prompt and rebuilding it with the LLM.
  /// Public JSON books and public "advanced" (JS) books are excluded — those are
  /// downloadable and live under the Public section. Matches JAR's
  /// `renderPublicBooks` private grouping (`!accessible && !isJs`).
  List<PublicLorebook> get _closedBooks => closedLorebooks(_public);

  /// The character's plain public books (1:1 conversion) and its public
  /// scripted ones (LLM rebuild) — the two halves the Public section renders,
  /// and together everything "Download all" works through.
  List<PublicLorebook> get _jsonBooks => publicJsonBooks(_public);
  List<PublicLorebook> get _jsBooks => publicJsBooks(_public);
  List<PublicLorebook> get _downloadableBooks =>
      downloadablePublicBooks(_public);

  /// Whether closed-lorebook extraction is currently possible: the user opted in
  /// and is logged into Janitor.AI, and no capture is already running.
  bool get _canRebuild {
    final loggedIn = ref.watch(janitorAccountProvider).isLoggedIn;
    final enabled =
        ref.watch(appSettingsProvider).value?.extractJanitorLocally ?? false;
    return loggedIn && enabled && !_proxyForbidden && !_extracting;
  }

  /// The creator locked this character to JanitorAI's own model, so the capture
  /// the rebuild depends on can never run. Known from the catalog metadata, no
  /// request needed — the button stays off instead of failing on press.
  bool get _proxyForbidden => !janitorAllowsProxy(widget.args.meta);

  /// Id of the JS lorebook currently being rebuilt by the LLM (per-row spinner).
  String? _jsBuildingId;

  /// "Download all" run state: true while the batch converts + saves, with
  /// [_savedAllDone] of [_savedAllTotal] books already through. Mutually
  /// exclusive with the per-row actions in both directions — one LLM rebuild at
  /// a time, and no per-row save landing in the middle of the batch.
  bool _savingAll = false;
  int _savedAllDone = 0;
  int _savedAllTotal = 0;

  /// Public scripts converted into entries during this session, by book id.
  ///
  /// A public script is a public lorebook whose entries simply aren't readable
  /// until an LLM has rebuilt them — so until it is converted, its content
  /// cannot be subtracted from the closed lorebook the way a plain public book's
  /// is, and the same entries turn up in both. Once converted they can, and are:
  /// see [_publicScriptContents].
  final Map<String, Lorebook> _convertedScripts = {};

  @override
  void initState() {
    super.initState();
    _loadPublic();
    final seeded = widget.initialExtraction;
    if (seeded != null) {
      _extraction = seeded;
      _nameController.text =
          '${seeded.character.charData.name} — Closed Lorebook';
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _extractExtraController.dispose();
    _buildExtraController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadPublic() async {
    final books = await fetchPublicLorebooks(widget.args.meta);
    if (!mounted) return;
    setState(() {
      _public = books;
      _loadingPublic = false;
    });
  }

  // ─── Public lorebook actions ───────────────────────────────────────────────

  void _downloadPublic(PublicLorebook book) {
    if (_savingAll) return;
    GlazeBottomSheet.show<void>(
      context,
      items: [
        BottomSheetItem(
          icon: Icons.bookmark_add_outlined,
          label: 'catalog_lorebooks_save'.tr(),
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await _saveLorebook(
              book.toLorebook(characterId: widget.characterId),
            );
          },
        ),
        BottomSheetItem(
          icon: Icons.download_outlined,
          label: 'catalog_lorebooks_export'.tr(),
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await _exportJson(
              book.toTavernJson(),
              book.title.isNotEmpty ? book.title : 'lorebook',
            );
          },
        ),
      ],
    );
  }

  /// Download action for a public **advanced (JS)** lorebook. Unlike a JSON book
  /// it can't be saved as-is, so tapping download first explains that the script
  /// must be sent to the active LLM for a rebuild, then (on confirm) runs
  /// [_buildJs]. Port of JAR's public JS "Build .json" affordance, reframed as a
  /// download that opens a rebuild explanation.
  void _downloadJs(PublicLorebook book) {
    if (_savingAll) return;
    GlazeBottomSheet.show<void>(
      context,
      title: 'catalog_lorebooks_scripted_title'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.code_rounded,
        description: 'catalog_lorebooks_scripted_desc'.tr(),
        buttonText: 'catalog_lorebooks_scripted_btn'.tr(),
        onButtonTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          _buildJs(book);
        },
      ),
    );
  }

  /// Rebuild a public **JavaScript** lorebook into keyed entries with the active
  /// LLM, then offer the same Save/Export destinations as a public JSON book.
  Future<void> _buildJs(PublicLorebook book) async {
    if (_savingAll) return;
    setState(() => _jsBuildingId = book.id);
    try {
      final lb = await ref
          .read(janitorExtractorProvider)
          .buildLorebookFromJs(
            jsSource: book.jsSource,
            name: book.title.isNotEmpty ? book.title : 'Janitor Lorebook',
            meta: widget.args.meta,
            characterId: widget.characterId,
          );
      if (!mounted) return;
      setState(() {
        _jsBuildingId = null;
        _convertedScripts[book.id] = lb;
      });
      _offerSaveExport(lb);
    } catch (e) {
      if (!mounted) return;
      setState(() => _jsBuildingId = null);
      GlazeToast.show(
        context,
        'catalog_lorebooks_build_failed'.tr(
          args: [
            describeCatalogError(
              e,
              fallback: CatalogErrorSource.provider,
            ).inline,
          ],
        ),
      );
    }
  }

  /// Convert **every** public lorebook of the section and save it to Glaze in
  /// one pass — the section's bulk action, for the common case of wanting all
  /// of them rather than tapping through each row's destination sheet.
  ///
  /// Plain books map 1:1; scripted ones go through the same LLM rebuild
  /// [_buildJs] runs (and are recorded in [_convertedScripts] just the same, so
  /// their entries stop being counted as closed-lorebook text). A script
  /// already converted this session is reused instead of paying for a second
  /// rebuild. One book failing never aborts the rest — the summary toast names
  /// what did not make it.
  Future<void> _downloadAllPublic() async {
    if (_savingAll || _jsBuildingId != null) return;
    final books = _downloadableBooks;
    if (books.isEmpty) return;
    setState(() {
      _savingAll = true;
      _savedAllDone = 0;
      _savedAllTotal = books.length;
    });
    var saved = 0;
    final failed = <String>[];
    try {
      for (final book in books) {
        try {
          final converted = _convertedScripts[book.id];
          final lb = !book.isJs
              ? book.toLorebook(characterId: widget.characterId)
              : converted ??
                    await ref
                        .read(janitorExtractorProvider)
                        .buildLorebookFromJs(
                          jsSource: book.jsSource,
                          name: book.title.isNotEmpty
                              ? book.title
                              : 'Janitor Lorebook',
                          meta: widget.args.meta,
                          characterId: widget.characterId,
                        );
          // The sheet can be closed mid-run: stop before writing anything more,
          // whatever was already saved stays saved.
          if (!mounted) return;
          await ref.read(lorebooksProvider.notifier).addLorebook(lb);
          if (!mounted) return;
          if (book.isJs) _convertedScripts[book.id] = lb;
          saved++;
        } catch (e) {
          debugPrint('[janitor-lorebook] save-all ${book.id} failed: $e');
          failed.add(book.title.isEmpty ? book.id : book.title);
        }
        if (!mounted) return;
        setState(() => _savedAllDone++);
      }
    } finally {
      if (mounted) setState(() => _savingAll = false);
    }
    if (!mounted) return;
    GlazeToast.show(
      context,
      failed.isEmpty
          ? 'catalog_lorebooks_saved_all'.tr(args: ['$saved'])
          : 'catalog_lorebooks_saved_all_partial'.tr(
              args: ['$saved', '${books.length}', failed.join(', ')],
            ),
    );
  }

  /// The entry text of every public script converted so far — subtracted from
  /// the closed lorebook exactly like a downloadable public book's entries.
  List<String> get _publicScriptContents => _convertedScripts.values
      .expand((b) => b.entries)
      .map((e) => e.content.trim())
      .where((c) => c.isNotEmpty)
      .toList();

  /// [text] with the entries of any converted public script cut out.
  ///
  /// The capture subtracts what was known at the time; a script converted
  /// *after* it would otherwise leave its entries sitting in the closed lorebook
  /// as well. Applied wherever the extracted text is read — shown, built,
  /// previewed, downloaded — rather than written back, so converting one more
  /// script needs no re-capture.
  String _withoutPublicScripts(String text) =>
      withoutPublicEntries(text, _publicScriptContents);

  /// Bottom sheet offering Save-to-Glaze / Export-.json for a built [Lorebook].
  void _offerSaveExport(Lorebook book) {
    GlazeBottomSheet.show<void>(
      context,
      items: [
        BottomSheetItem(
          icon: Icons.bookmark_add_outlined,
          label: 'catalog_lorebooks_save'.tr(),
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await _saveLorebook(book);
          },
        ),
        BottomSheetItem(
          icon: Icons.download_outlined,
          label: 'catalog_lorebooks_export'.tr(),
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await _exportJson(glazeLorebookToTavernJson(book), book.name);
          },
        ),
      ],
    );
  }

  Future<void> _saveLorebook(Lorebook book) async {
    try {
      await ref.read(lorebooksProvider.notifier).addLorebook(book);
      if (mounted) {
        GlazeToast.show(
          context,
          'catalog_lorebooks_saved'.tr(
            args: [book.name, '${book.entries.length}'],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        GlazeToast.show(
          context,
          'catalog_lorebooks_save_failed'.tr(args: [formatError(e)]),
        );
      }
    }
  }

  Future<void> _exportJson(Map<String, dynamic> json, String name) async {
    try {
      final safe = name.replaceAll(RegExp(r'[^\w\- ]+'), '').trim();
      await FileExportService.export(
        data: const JsonEncoder.withIndent('  ').convert(json),
        filename: '${safe.isEmpty ? 'lorebook' : safe}.json',
        subfolder: 'Lorebooks',
      );
      if (mounted) {
        GlazeToast.show(
          context,
          'catalog_lorebooks_exported'.tr(args: ['$name.json']),
        );
      }
    } catch (e) {
      if (mounted) {
        GlazeToast.show(
          context,
          'catalog_lorebooks_export_failed'.tr(args: [formatError(e)]),
        );
      }
    }
  }

  // ─── Closed-lorebook extraction + build ─────────────────────────────────────

  /// Rebuild **all** the character's closed lorebooks in one pass. The capture
  /// step assembles the character's full prompt through the Janitor.AI session
  /// (not a single book), so every closed book is recovered together and merged
  /// into one — a single action covers them all, no per-row button.
  Future<void> _extractAll() async {
    if (_extracting) return;
    final extra =
        _extractSources.extra ? _extractExtraController.text.trim() : '';
    setState(() {
      _extracting = true;
      _extractError = null;
      _extractPhase = null;
      _extraction = null;
      _built = null;
      _buildError = null;
      _buildDebug = null;
    });
    try {
      final result = await ref
          .read(janitorExtractorProvider)
          .extract(
            widget.args.sourceUrl,
            extraPublicContents: _publicScriptContents,
            trigger: JanitorTriggerContext(
              card: _extractSources.card,
              catalog: _extractSources.catalog,
              scenario: _extractSources.scenario,
              greetings: _extractSources.greetings,
              lorebookDescs: _extractSources.lorebookDescs,
              extra: extra,
            ),
            onPhase: (p) {
              if (mounted) setState(() => _extractPhase = p);
            },
          );
      if (!mounted) return;
      setState(() {
        _extraction = result;
        // Carry the extraction choice into the build, like JAR's
        // `runLoreExtract`: the sources that made the entries fire are usually
        // the ones that describe them best. Still editable before building.
        _buildSources.copyFrom(_extractSources);
        _buildExtraController.text = extra;
        if (_nameController.text.trim().isEmpty) {
          _nameController.text =
              '${result.character.charData.name} — Closed Lorebook';
        }
      });
    } catch (e) {
      // Everything the capture talks to is Janitor.AI, so a failure with no
      // source of its own is labelled as theirs. JanitorAI refusing to assemble
      // the prompt (creator locked the card to their own model) is a permanent
      // answer, not a failure worth retrying — `describeCatalogError` quotes its
      // wording and says what it means for these books.
      if (mounted) {
        setState(() {
          _extractError = describeCatalogError(
            e,
            fallback: CatalogErrorSource.janitor,
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _extracting = false;
        });
      }
    }
  }

  Future<void> _build() async {
    final ex = _extraction;
    if (ex == null) return;
    setState(() {
      _building = true;
      _buildError = null;
      _buildDebug = null;
      _built = null;
      _elapsed = 0;
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
    try {
      final book = await ref
          .read(janitorExtractorProvider)
          .buildLorebook(
            lorebookText: _withoutPublicScripts(ex.lorebookText),
            name: _nameController.text.trim().isEmpty
                ? '${ex.character.charData.name} — Closed Lorebook'
                : _nameController.text.trim(),
            card: _buildSources.card ? ex.cardContext : '',
            catalog: _buildSources.catalog ? ex.catalogContext : '',
            scenario: _buildSources.scenario ? ex.scenarioContext : '',
            greetings: _buildSources.greetings ? ex.greetingsContext : '',
            lorebookDescs: _buildSources.lorebookDescs
                ? ex.lorebookDescsContext
                : '',
            extra: _buildSources.extra ? _buildExtraController.text.trim() : '',
            characterId: widget.characterId,
          );
      if (mounted) setState(() => _built = book);
    } catch (e) {
      // The build stage only ever talks to the user's own LLM connection, so
      // an unlabelled failure here is the provider's.
      if (mounted) {
        setState(() {
          _buildError = describeCatalogError(
            e,
            fallback: CatalogErrorSource.provider,
          );
          _buildDebug = e is LorebookBuildException ? e : null;
        });
      }
    } finally {
      _timer?.cancel();
      if (mounted) setState(() => _building = false);
    }
  }

  /// [book] under the name currently in the world-info field, or unchanged when
  /// the field is empty or already matches.
  Lorebook _named(Lorebook book) {
    final name = _nameController.text.trim();
    return name.isEmpty || name == book.name ? book : book.copyWith(name: name);
  }

  /// Show the exact messages the build would send, in their own sheet — the
  /// prompt carries the whole extracted text, far too much to unfold inline.
  void _preview() {
    final ex = _extraction;
    if (ex == null) return;
    showJanitorPromptPreviewSheet(
      context,
      buildLorebookMessages(
        _withoutPublicScripts(ex.lorebookText),
        // The preview must show what the build would really send, so it takes
        // the same system prompt — the edited one when the user changed it in
        // the extraction settings.
        systemPrompt: lorebookSystemPrompt(
          ref.read(appSettingsProvider).value,
        ),
        card: _buildSources.card ? ex.cardContext : '',
        catalog: _buildSources.catalog ? ex.catalogContext : '',
        scenario: _buildSources.scenario ? ex.scenarioContext : '',
        greetings: _buildSources.greetings ? ex.greetingsContext : '',
        lorebookDescs:
            _buildSources.lorebookDescs ? ex.lorebookDescsContext : '',
        extra: _buildSources.extra ? _buildExtraController.text.trim() : '',
      ),
    );
  }

  /// Export the isolated lorebook text verbatim as a plain .txt file. Without an
  /// LLM the real entry boundaries and trigger keys can't be recovered, so we hand
  /// back the extracted content as-is for manual use rather than a keyless,
  /// over-segmented lorebook.
  Future<void> _downloadExtracted() async {
    final ex = _extraction;
    if (ex == null) return;
    final text = _withoutPublicScripts(ex.lorebookText).trim();
    if (text.isEmpty) {
      GlazeToast.show(context, 'catalog_lorebooks_nothing_to_download'.tr());
      return;
    }
    final name = _nameController.text.trim().isEmpty
        ? '${ex.character.charData.name} — Closed Lorebook (extracted)'
        : _nameController.text.trim();
    try {
      final safe = name.replaceAll(RegExp(r'[^\w\- ]+'), '').trim();
      await FileExportService.export(
        data: text,
        filename: '${safe.isEmpty ? 'lorebook' : safe}.txt',
        subfolder: 'Lorebooks',
      );
      if (mounted) {
        GlazeToast.show(
          context,
          'catalog_lorebooks_exported'.tr(args: ['$name.txt']),
        );
      }
    } catch (e) {
      if (mounted) {
        GlazeToast.show(
          context,
          'catalog_lorebooks_export_failed'.tr(args: [formatError(e)]),
        );
      }
    }
  }

  // ─── Build ──────────────────────────────────────────────────────────────────

  /// Whether this character has a closed-lorebook flow to run at all. Without
  /// closed books the sheet is just the list of public ones.
  bool get _hasFlow => !_loadingPublic && _closedBooks.isNotEmpty;

  /// Which stage of the closed-lorebook flow is on screen, derived from what
  /// has been produced so far rather than tracked separately.
  _Phase get _phase => !_hasFlow
      ? _Phase.collect
      : _built != null
      ? _Phase.save
      : _extraction != null
      ? _Phase.build
      : _Phase.collect;

  /// One step back through the flow, the way the header arrow goes.
  void _stepBack() {
    if (_built != null) {
      _restartBuild();
    } else {
      _restartCollection();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final closed = _closedBooks;
    return SheetView(
      // The help sits with the title it explains — the same inline [HelpTip]
      // every group header uses — and the header's action slot carries the
      // settings that change what the flow does.
      titleWidget: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              'catalog_lorebooks_title'.tr(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
          ),
          const HelpTip(term: _kHelpTermExtraction, size: 18),
        ],
      ),
      startExpanded: true,
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.tune_rounded, size: 20),
          tooltip: 'catalog_extraction_settings_title'.tr(),
          onPressed: () => showJanitorExtractionSettingsSheet(context),
        ),
      ],
      headerBottom: _hasFlow ? _phaseStrip(cs) : null,
      // No horizontal padding on the list: MenuGroup carries its own 16 px
      // margin, and the loose text between groups is padded individually.
      body: _loadingPublic
          ? const _SheetLoading()
          : Builder(
              builder: (inner) => ListView(
                padding: EdgeInsets.only(
                  top: MediaQuery.paddingOf(inner).top + 12,
                  bottom: MediaQuery.paddingOf(inner).bottom + 24,
                ),
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    // The outgoing stage is taken out of the layout (top-anchored
                    // and unconstrained in height) so the sheet takes the height
                    // of the stage arriving, instead of jumping to the taller of
                    // the two for the length of the fade.
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.topCenter,
                      children: [
                        for (final child in previous)
                          Positioned(left: 0, right: 0, top: 0, child: child),
                        ?current,
                      ],
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(_phase),
                      child: _stageContent(cs, closed),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// The one stage that is on screen. Only the first stage lists the character's
  /// lorebooks: past it they are settled reference material, and the flow is
  /// about the text recovered from them.
  Widget _stageContent(ColorScheme cs, List<PublicLorebook> closed) {
    final children = switch (_phase) {
      _Phase.collect => [
        _PublicSection(
          books: _public,
          onDownload: _downloadPublic,
          onDownloadJs: _downloadJs,
          onDownloadAll: _downloadAllPublic,
          buildingId: _jsBuildingId,
          savingAll: _savingAll,
          savedAllDone: _savedAllDone,
          savedAllTotal: _savedAllTotal,
        ),
        if (closed.isNotEmpty) ..._closedSection(cs, closed),
      ],
      _Phase.build => _buildBlock(cs, _extraction!),
      _Phase.save => _buildResult(_built!),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  /// The flow's stages, named under the sheet title, with a back arrow into the
  /// previous one. Replaces a per-stage "go back" button: the way back belongs
  /// with the label that says where you are, not in the middle of the content.
  Widget _phaseStrip(ColorScheme cs) {
    final phase = _phase;
    final showBack = phase != _Phase.collect;
    final canGoBack = showBack && !_building && !_extracting;
    return Row(
      children: [
        // On the first stage there is nowhere to go back to, so the arrow does
        // not merely hide — it takes no width, and the stage labels sit at the
        // left edge. It grows and fades in when a step back appears.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) => SizeTransition(
            sizeFactor: anim,
            axis: Axis.horizontal,
            alignment: Alignment.centerLeft,
            child: FadeTransition(opacity: anim, child: child),
          ),
          child: showBack
              ? Padding(
                  key: const ValueKey(true),
                  padding: const EdgeInsets.only(right: 6),
                  child: SizedBox(
                    width: 34,
                    height: 34,
                    child: Material(
                      color: Colors.transparent,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: canGoBack ? _stepBack : null,
                        child: Icon(
                          Icons.arrow_back_rounded,
                          size: 20,
                          color: cs.onSurfaceVariant.withValues(
                            alpha: canGoBack ? 1 : 0.3,
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : const SizedBox(key: ValueKey(false), height: 34),
        ),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                for (final (i, p) in _Phase.values.indexed) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                      ),
                    ),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: p == phase ? FontWeight.w700 : FontWeight.w500,
                      color: p == phase
                          ? cs.primary
                          : cs.onSurfaceVariant.withValues(
                              // Stages already passed stay legible; ones not
                              // reached yet are only a hint of what follows.
                              alpha: p.index < phase.index ? 0.7 : 0.35,
                            ),
                    ),
                    child: Text(p.label),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Stage 1 of the closed-lorebook flow: what the character has, what will be
  /// sent to make its entries fire, and the action that runs the capture. The
  /// later stages are [_buildBlock] and [_buildResult].
  List<Widget> _closedSection(ColorScheme cs, List<PublicLorebook> closed) {
    return [
      // The list itself is reference material, not a control — collapsed by
      // default so the flow below starts at the top of the sheet.
      MenuCollapsibleSection(
        label: '${'catalog_lorebooks_closed'.tr()} · ${closed.length}',
        helpTerm: 'janitor-closed-lorebook',
        children: [
          MenuGroup(
            items: [
              _GroupNote(
                closed.length > 1
                    ? 'catalog_lorebooks_closed_hint_many'.tr(
                        args: ['${closed.length}'],
                      )
                    : 'catalog_lorebooks_closed_hint_one'.tr(),
              ),
              for (final b in closed) _ClosedRow(book: b),
            ],
          ),
        ],
      ),
      // The extraction context sits ABOVE the action, like JAR's extract block:
      // what is sent into the chat to make entries fire is chosen before the
      // capture runs.
      _extractContextGroup(),
      // A single action for every closed book: the capture assembles the whole
      // prompt at once, so all closed lorebooks are collected together (not one
      // per row).
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: ActionTile(
          icon: Icons.auto_fix_high_rounded,
          expand: true,
          primary: true,
          busy: _extracting,
          // The capture's live phase reads inside the button it belongs to —
          // one busy control, not a button plus a status line under it.
          label: _extracting
              ? (_extractPhase ?? 'catalog_lorebooks_extracting'.tr())
              : 'catalog_lorebooks_collect_btn'.tr(),
          onTap: _canRebuild ? _extractAll : null,
        ),
      ),
      _buildExtractStatus(cs),
    ];
  }

  /// Back to stage 1: drop the capture (and anything built from it) so the
  /// extraction context can be picked again. Deliberately does not re-run the
  /// capture — the whole point of coming back is to change what is sent.
  void _restartCollection() {
    setState(() {
      _extraction = null;
      _built = null;
      _buildError = null;
      _buildDebug = null;
      _extractError = null;
      _extractPhase = null;
    });
  }

  /// Back to stage 2: keep the collected entries, drop the built lorebook so
  /// the key-inference context can be changed and the build re-run.
  void _restartBuild() {
    setState(() {
      _built = null;
      _buildError = null;
      _buildDebug = null;
    });
  }

  /// Why the collect action is unavailable (proxies forbidden, opt-in off, not
  /// logged in), plus any capture error. The live phase is not here — it reads
  /// inside the button.
  Widget _buildExtractStatus(ColorScheme cs) {
    final loggedIn = ref.watch(janitorAccountProvider).isLoggedIn;
    final enabled =
        ref.watch(appSettingsProvider).value?.extractJanitorLocally ?? false;
    // Proxies forbidden outranks the other two: enabling the opt-in or logging
    // in would not make the capture possible.
    final hint = _proxyForbidden
        ? '${const JanitorRefusedException.proxyForbidden().message}. '
              '${'catalog_janitor_refused_body'.tr()}'
        : !enabled
        ? 'catalog_lorebooks_need_optin'.tr()
        : !loggedIn
        ? 'catalog_lorebooks_need_login'.tr()
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _Hint(hint, cs: cs),
          ),
        if (_extractError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: GlazeErrorBlock(
              message: _extractError!.message,
              label: _extractError!.label,
            ),
          ),
      ],
    );
  }

  /// Stage 2 — everything between a finished capture and a built lorebook: what
  /// was recovered, the context selection that feeds key inference, and the
  /// build / preview actions.
  ///
  /// Laid out as Glaze menu groups (see `docs/UI_KIT.md`) and kept at feature
  /// parity with JAR's build block — the same six context sources, each with
  /// its token count and its exact content one tap away, plus custom text.
  List<Widget> _buildBlock(ColorScheme cs, ExtractionResult ex) {
    final loreText = _withoutPublicScripts(ex.lorebookText);
    final hasLore = loreText.trim().isNotEmpty;
    return [
      MenuGroup(
        header: 'catalog_lorebooks_build_title'.tr(),
        helpTerm: 'lorebook',
        description: hasLore
            ? 'catalog_lorebooks_build_extracted'.tr(
                args: ['${estimateTokens(loreText)}'],
              )
            : 'catalog_lorebooks_build_none'.tr(),
        items: [
          // What the capture actually recovered, verbatim — the same look at
          // the material JAR gives before the build runs.
          if (hasLore)
            DisclosureRow(
              label: 'catalog_lorebooks_extracted_content'.tr(),
              subtitle: 'catalog_lorebooks_extracted_content_sub'.tr(),
              content: loreText,
            ),
          // Say when the field diff found lore the separator alone would have
          // dropped — otherwise the recovery is invisible and reads as the
          // model having invented entries out of the extracted text.
          if (ex.injected.isNotEmpty)
            _GroupNote(
              'catalog_lorebooks_injected_note'.tr(
                args: ['${ex.injected.length}'],
              ),
              top: 4,
            ),
          // Without an LLM the real entry boundaries and keys can't be
          // recovered, so the raw text is offered as-is instead.
          if (hasLore)
            MenuItem(
              icon: Icons.notes_rounded,
              label: 'catalog_lorebooks_download_txt'.tr(),
              subtitle: 'catalog_lorebooks_download_txt_sub'.tr(),
              onTap: _downloadExtracted,
            ),
        ],
      ),
      if (hasLore) ...[
        _keyContextGroup(ex),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionTile(
                icon: Icons.auto_awesome_rounded,
                label: _building
                    ? 'catalog_lorebooks_building'.tr(args: ['$_elapsed'])
                    : 'catalog_lorebooks_build_btn'.tr(),
                primary: true,
                busy: _building,
                onTap: _build,
              ),
              ActionTile(
                icon: Icons.visibility_outlined,
                label: 'catalog_lorebooks_preview_btn'.tr(),
                onTap: _building ? null : _preview,
              ),
            ],
          ),
        ),
        // A build is one long non-streaming request over the whole extracted
        // text; on a slow model it sits silent for minutes. Say so next to the
        // button rather than let it read as a hang.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.schedule_rounded,
                size: 14,
                color: cs.onSurfaceVariant.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'catalog_lorebooks_build_patience'.tr(),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_buildError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: GlazeErrorBlock(
              message: _buildError!.message,
              label: _buildError!.label,
            ),
          ),
        if (_buildDebug != null) ...[
          _LlmDebugPanel(error: _buildDebug!, cs: cs),
          const SizedBox(height: 12),
        ],
      ],
    ];
  }

  /// The built lorebook and its two destinations. The world-info name lives
  /// here rather than next to the build controls: it is a property of the book
  /// being filed away, so it is asked for at the moment it is used — the name
  /// under which it is saved to the library or written to a `.json`.
  List<Widget> _buildResult(Lorebook book) {
    return [
      MenuGroup(
        header: 'catalog_lorebooks_built'.tr(args: ['${book.entries.length}']),
        items: [
          MenuFieldItem(
            label: 'catalog_lorebooks_world_name'.tr(),
            controller: _nameController,
            placeholder: book.name,
          ),
          MenuItem(
            icon: Icons.bookmark_add_outlined,
            label: 'catalog_lorebooks_save'.tr(),
            onTap: () => _saveLorebook(_named(book)),
          ),
          MenuItem(
            icon: Icons.download_outlined,
            label: 'catalog_lorebooks_export'.tr(),
            subtitle: 'catalog_lorebooks_export_sub'.tr(),
            onTap: () {
              final named = _named(book);
              _exportJson(glazeLorebookToTavernJson(named), named.name);
            },
          ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: ContentPane(
          mono: true,
          maxHeight: 220,
          text: const JsonEncoder.withIndent(
            '  ',
          ).convert(glazeLorebookToTavernJson(book)),
        ),
      ),
    ];
  }

  /// JAR's `#loreExtractBlock`: what Glaze sends **into the JanitorAI chat** so
  /// the closed lorebook's entries fire. The contents shown are the ones that
  /// will actually be sent — all derived from the character's catalog metadata,
  /// except the card, which the capture is what recovers.
  Widget _extractContextGroup() {
    return MenuGroup(
      header: 'catalog_lorebooks_extract_title'.tr(),
      helpTerm: 'janitor-extract-context',
      description: 'catalog_lorebooks_extract_hint'.tr(),
      items: [
        ContextSourceTile(
          label: 'catalog_ctx_card'.tr(),
          content: _extraction?.cardContext ?? '',
          // The card only exists inside the assembled prompt, so before the
          // capture there is nothing to show — but the capture's first send
          // reveals it in time for the trigger, so the switch stays live.
          emptyNote: 'catalog_ctx_card_pending'.tr(),
          pending: _extraction == null,
          value: _extractSources.card,
          onChanged: (v) => setState(() => _extractSources.card = v),
        ),
        ContextSourceTile(
          label: 'catalog_ctx_catalog'.tr(),
          content: _previewCtx.catalog,
          value: _extractSources.catalog,
          onChanged: (v) => setState(() => _extractSources.catalog = v),
        ),
        ContextSourceTile(
          label: 'catalog_ctx_scenario'.tr(),
          content: _previewCtx.scenario,
          value: _extractSources.scenario,
          onChanged: (v) => setState(() => _extractSources.scenario = v),
        ),
        ContextSourceTile(
          label: 'catalog_ctx_greetings'.tr(),
          content: _previewCtx.greetings,
          value: _extractSources.greetings,
          onChanged: (v) => setState(() => _extractSources.greetings = v),
        ),
        ContextSourceTile(
          label: 'catalog_ctx_lorebook_descs'.tr(),
          content: buildLorebookDescsContext(_public),
          value: _extractSources.lorebookDescs,
          onChanged: (v) => setState(() => _extractSources.lorebookDescs = v),
        ),
        MenuSwitchItem(
          label: 'catalog_ctx_extra'.tr(),
          description: 'catalog_ctx_extra_desc'.tr(),
          value: _extractSources.extra,
          onChanged: (v) => setState(() => _extractSources.extra = v),
        ),
        if (_extractSources.extra)
          MenuFieldItem(
            label: 'catalog_ctx_extra_label'.tr(),
            controller: _extractExtraController,
            maxLines: 4,
            placeholder: 'catalog_ctx_extra_ph'.tr(),
          ),
      ],
    );
  }

  /// JAR's `#useSources`: the six context sources the build LLM may read to
  /// infer trigger keys (never emitted as entries). Only reachable after a
  /// capture, so every source is shown with the text the capture recovered.
  Widget _keyContextGroup(ExtractionResult ex) {
    return MenuGroup(
      header: 'catalog_lorebooks_key_context_title'.tr(),
      helpTerm: 'lorebook-key-context',
      description: 'catalog_lorebooks_key_context_hint'.tr(),
      items: [
        ContextSourceTile(
          label: 'catalog_ctx_card'.tr(),
          content: ex.cardContext,
          value: _buildSources.card,
          onChanged: (v) => setState(() => _buildSources.card = v),
        ),
        ContextSourceTile(
          label: 'catalog_ctx_catalog'.tr(),
          content: ex.catalogContext,
          value: _buildSources.catalog,
          onChanged: (v) => setState(() => _buildSources.catalog = v),
        ),
        ContextSourceTile(
          label: 'catalog_ctx_scenario'.tr(),
          content: ex.scenarioContext,
          value: _buildSources.scenario,
          onChanged: (v) => setState(() => _buildSources.scenario = v),
        ),
        ContextSourceTile(
          label: 'catalog_ctx_greetings'.tr(),
          content: ex.greetingsContext,
          value: _buildSources.greetings,
          onChanged: (v) => setState(() => _buildSources.greetings = v),
        ),
        ContextSourceTile(
          label: 'catalog_ctx_lorebook_descs'.tr(),
          content: ex.lorebookDescsContext,
          value: _buildSources.lorebookDescs,
          onChanged: (v) => setState(() => _buildSources.lorebookDescs = v),
        ),
        MenuSwitchItem(
          label: 'catalog_ctx_extra'.tr(),
          description: 'catalog_ctx_extra_desc'.tr(),
          value: _buildSources.extra,
          onChanged: (v) => setState(() => _buildSources.extra = v),
        ),
        if (_buildSources.extra)
          MenuFieldItem(
            label: 'catalog_ctx_extra_label'.tr(),
            controller: _buildExtraController,
            maxLines: 4,
            placeholder: 'catalog_ctx_extra_ph'.tr(),
          ),
      ],
    );
  }
}

// ─── Sub-widgets ──────────────────────────────────────────────────────────────

/// What the sheet shows until the character's lorebooks are known: nothing can
/// be listed and no stage can be entered yet, so the whole sheet is the wait.
class _SheetLoading extends StatelessWidget {
  const _SheetLoading();

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 44, height: 44, child: GlazeSpinner(color: cs.primary)),
          const SizedBox(height: 18),
          Text(
            'catalog_lorebooks_loading'.tr(),
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _PublicSection extends StatelessWidget {
  final List<PublicLorebook> books;
  final void Function(PublicLorebook) onDownload;
  final void Function(PublicLorebook) onDownloadJs;

  /// Convert + save every book of the section in one pass.
  final VoidCallback onDownloadAll;
  final String? buildingId;

  /// The batch is running: rows stop offering their own action (one save flow
  /// at a time) and the bulk button reads `done/total`.
  final bool savingAll;
  final int savedAllDone;
  final int savedAllTotal;
  const _PublicSection({
    required this.books,
    required this.onDownload,
    required this.onDownloadJs,
    required this.onDownloadAll,
    required this.buildingId,
    required this.savingAll,
    required this.savedAllDone,
    required this.savedAllTotal,
  });

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    // Everything downloadable goes under the single "Public lorebooks" headline:
    //  - JSON books map 1:1 and download whole (no LLM);
    //  - "advanced" / Nine API books are public but shipped as a script, so they
    //    carry a Convert action instead and are rebuilt with the LLM.
    // Private/locked books are NOT shown here — they belong to the closed section.
    final json = publicJsonBooks(books);
    final js = publicJsBooks(books);
    final hasClosed = closedLorebooks(books).isNotEmpty;
    // With both kinds attached a flat list would mix two different actions
    // (download vs. convert), so it splits into "Lorebooks" and "Scripts"
    // sub-groups. With only one kind there is nothing to tell apart and the rows
    // stay flat under the section headline.
    final split = json.isNotEmpty && js.isNotEmpty;
    if (json.isEmpty && js.isEmpty) {
      // No downloadable books. Stay silent when there are closed books (the
      // closed section carries the messaging); otherwise say there are none.
      if (hasClosed) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(
          'catalog_lorebooks_none'.tr(),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      );
    }
    // Collapsed by default: these rows are a catalogue of what the character
    // carries, not part of the extraction flow, and that flow should start at
    // the top of the sheet. The count keeps the fact of them visible.
    return MenuCollapsibleSection(
      label: '${'catalog_lorebooks_public'.tr()} · ${json.length + js.length}',
      helpTerm: 'lorebook',
      children: [
        MenuGroup(
          items: [
            _GroupNote(
              [
                'catalog_lorebooks_public_hint'.tr(),
                // Public entries are subtracted from the closed-lorebook text,
                // so the two sections never carry the same content twice.
                if (hasClosed) 'catalog_lorebooks_public_hint_closed'.tr(),
                // Unsplit, the scripted caveat has no sub-group header to live
                // under, so it rides along with the section note.
                if (js.isNotEmpty && !split)
                  'catalog_lorebooks_public_hint_scripted'.tr(),
              ].join(' '),
            ),
            if (split) MenuSubHeader('catalog_lorebooks_group_books'.tr()),
            for (final b in json)
              _PublicRow(
                book: b,
                onDownload: savingAll ? null : () => onDownload(b),
              ),
            if (split) ...[
              MenuSubHeader('catalog_lorebooks_group_scripts'.tr()),
              _GroupNote('catalog_lorebooks_group_scripts_note'.tr(), top: 2),
            ],
            for (final b in js)
              _PublicRow(
                book: b,
                onDownload: savingAll ? null : () => onDownloadJs(b),
                building: buildingId == b.id,
              ),
            // The bulk action closes the group: with a single book it would
            // only duplicate that row, so it appears from two on.
            if (json.length + js.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: ActionTile(
                  icon: Icons.library_add_rounded,
                  expand: true,
                  primary: true,
                  busy: savingAll,
                  // Progress reads inside the button that owns it, like the
                  // capture action — one busy control, no status line under it.
                  label: savingAll
                      ? 'catalog_lorebooks_download_all_busy'.tr(
                          args: ['$savedAllDone', '$savedAllTotal'],
                        )
                      : 'catalog_lorebooks_download_all'.tr(
                          args: ['${json.length + js.length}'],
                        ),
                  // A single JS rebuild in flight owns the LLM: let it finish
                  // rather than queue a second one behind it.
                  onTap: buildingId == null ? onDownloadAll : null,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// One public lorebook as a menu row: title, what it is, its description, and
/// the action it actually supports — a download affordance for a JSON book, a
/// Convert button for a scripted one (which becomes a spinner while its rebuild
/// runs). The row stays tappable and does the same thing, so the button labels
/// the action rather than being the only way to reach it.
class _PublicRow extends StatelessWidget {
  final PublicLorebook book;
  final VoidCallback? onDownload;
  final bool building;
  const _PublicRow({
    required this.book,
    this.onDownload,
    this.building = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final desc = book.description.trim();
    return MenuItem(
      icon: book.isJs ? Icons.code_rounded : Icons.menu_book_rounded,
      label: book.title.isEmpty ? 'Lorebook' : book.title,
      subtitle: [
        book.isJs
            ? 'catalog_lorebook_kind_scripted'.tr()
            : 'catalog_lorebook_kind_public'.tr(args: ['${book.entryCount}']),
        if (desc.isNotEmpty) desc,
      ].join('\n'),
      trailing: book.isJs
          ? ActionTile(
              icon: Icons.auto_fix_high_rounded,
              label: 'catalog_lorebooks_convert_btn'.tr(),
              compact: true,
              primary: true,
              busy: building,
              onTap: onDownload,
            )
          : building
          ? SizedBox(
              width: 18,
              height: 18,
              child: GlazeSpinner(color: cs.primary),
            )
          : Icon(Icons.download_rounded, size: 20, color: cs.primary),
      onTap: building ? () {} : (onDownload ?? () {}),
    );
  }
}

/// A closed lorebook as a menu row. There is no per-row action — one capture
/// recovers every closed book at once — so it is a plain row, not a [MenuItem].
class _ClosedRow extends StatelessWidget {
  final PublicLorebook book;
  const _ClosedRow({required this.book});

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final desc = book.description.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.lock_outline,
            size: 22,
            color: cs.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.title.isEmpty ? 'Lorebook' : book.title,
                  style: TextStyle(fontSize: 16, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 2),
                Text(
                  'catalog_lorebook_kind_closed'.tr(),
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                  ),
                ),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    desc,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the exact messages the build LLM would receive as a sheet of their
/// own. Port of JAR's `#promptPreview`, promoted out of an inline disclosure:
/// the prompt carries the whole extracted lorebook, so reading it inside the
/// capture sheet meant scrolling the flow away to get to it.
void showJanitorPromptPreviewSheet(
  BuildContext context,
  List<Map<String, String>> messages,
) {
  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (_) => _PromptPreviewSheet(messages: messages),
  );
}

class _PromptPreviewSheet extends StatelessWidget {
  final List<Map<String, String>> messages;
  const _PromptPreviewSheet({required this.messages});

  String get _plainText =>
      messages.map((m) => '### ${m['role']}\n${m['content']}').join('\n\n');

  @override
  Widget build(BuildContext context) {
    return SheetView(
      // Deliberately not expanded: the preview is something you glance at
      // beside the build controls, not a screen you move into.
      title: 'catalog_lorebooks_prompt_preview'.tr(),
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.copy_rounded, size: 20),
          tooltip: 'action_copy'.tr(),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: _plainText));
            if (context.mounted) {
              GlazeToast.show(context, 'chat_copied'.tr());
            }
          },
        ),
      ],
      body: Builder(
        builder: (inner) => ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(inner).top + 12,
            bottom: MediaQuery.paddingOf(inner).bottom + 24,
          ),
          children: [
            for (final m in messages)
              MenuGroup(
                header: m['role'] ?? '',
                description: 'catalog_ctx_tokens'.tr(
                  args: ['${estimateTokens(m['content'] ?? '')}'],
                ),
                // No inner scroll view: the message is laid out in full and the
                // sheet's own list scrolls it, so a long prompt reads as one
                // continuous document instead of a stack of tiny panes.
                items: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
                    child: SelectableText(
                      m['content'] ?? '',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.45,
                        fontFamily: 'monospace',
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// A muted note rendered as the first row inside a [MenuGroup] — the group's
/// `description` slot needs a header, and these groups are titled by the
/// collapsible section wrapping them instead.
class _GroupNote extends StatelessWidget {
  final String text;

  /// Space above the note. Defaults to the gap a note needs when it opens a
  /// group; a note sitting directly under a sub-header passes a smaller one, the
  /// header having already spaced itself off whatever came before.
  final double top;
  const _GroupNote(this.text, {this.top = 14});

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(16, top, 16, 4),
    child: Text(
      text,
      style: const TextStyle(
        color: Color(0xFF99A2AD),
        fontSize: 12,
        height: 1.35,
      ),
    ),
  );
}

/// Collapsible diagnostics for a failed LLM build: the raw provider payload,
/// the assistant text and any reasoning stream — so the cause (empty content,
/// reasoning-only response, content filter, truncation) is visible in-app.
class _LlmDebugPanel extends StatelessWidget {
  final LorebookBuildException error;
  final ColorScheme cs;
  const _LlmDebugPanel({required this.error, required this.cs});

  @override
  Widget build(BuildContext context) {
    final sections = <(String, String)>[
      if ((error.rawResponseJson ?? '').isNotEmpty)
        ('Raw provider payload', error.rawResponseJson!),
      if (error.rawText.trim().isNotEmpty)
        ('Assistant text', error.rawText)
      else
        ('Assistant text', '(empty)'),
      if ((error.reasoning ?? '').isNotEmpty)
        ('Reasoning stream', error.reasoning!),
    ];
    return MenuCollapsibleSection(
      label: 'catalog_lorebooks_llm_debug'.tr(),
      children: [
        for (final (label, body) in sections)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$label · ${'catalog_ctx_tokens'.tr(args: ['${estimateTokens(body)}'])}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy_rounded, size: 14),
                      color: cs.onSurfaceVariant,
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: body));
                        if (context.mounted) {
                          GlazeToast.show(context, 'Copied $label');
                        }
                      },
                    ),
                  ],
                ),
                ContentPane(text: body, mono: true, maxHeight: 200),
              ],
            ),
          ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;
  final ColorScheme cs;
  const _Hint(this.text, {required this.cs});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
    ),
  );
}

