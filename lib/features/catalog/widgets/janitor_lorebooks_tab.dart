import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/tokenizer.dart';
import '../../../core/models/lorebook.dart';
import '../../../core/services/file_export_service.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../settings/app_settings_provider.dart';
import '../janitor_account_provider.dart';
import '../services/janitor_extractor.dart';
import '../services/janitor_lorebook_rebuilder.dart';
import '../services/janitor_public_lorebook.dart';

/// Context passed to the catalog-preview Lorebooks tab. Carries the JanitorAI
/// character id, its source URL and the raw `/hampter` metadata (for the
/// attached `scripts`).
class JanitorLorebookArgs {
  final String characterId;
  final String sourceUrl;
  final Map<String, dynamic> meta;
  final bool definitionPublic;

  const JanitorLorebookArgs({
    required this.characterId,
    required this.sourceUrl,
    required this.meta,
    this.definitionPublic = false,
  });
}

/// The catalog card sheet's **Lorebooks** tab — a Flutter port of JAR's
/// `#tabLorebook` UI.
///
/// - **Public lorebooks** attached to the character are downloaded whole
///   (`/hampter/script/{id}`) and can be saved to Glaze or exported as a
///   SillyTavern World Info `.json`.
/// - **Closed lorebooks** are recovered by capturing the assembled prompt via
///   the proxy ([JanitorExtractor.extract]) and rebuilt into structured entries
///   with the active LLM ([JanitorExtractor.buildLorebook]). Context-source
///   checkboxes pick what the build LLM may use to infer trigger keys.
class JanitorLorebooksTab extends ConsumerStatefulWidget {
  final JanitorLorebookArgs args;
  const JanitorLorebooksTab({super.key, required this.args});

  @override
  ConsumerState<JanitorLorebooksTab> createState() =>
      _JanitorLorebooksTabState();
}

/// Which context blocks the build LLM may use to infer trigger keys.
class _ContextSources {
  bool card = true;
  bool catalog = true;
  bool scenario = true;
  bool greetings = false;
  bool lorebookDescs = true;
  bool extra = false;
}

class _JanitorLorebooksTabState extends ConsumerState<JanitorLorebooksTab> {
  // Public lorebooks.
  bool _loadingPublic = true;
  List<PublicLorebook> _public = const [];

  // Closed-lorebook extraction.
  bool _extracting = false;
  String? _extractPhase;
  String? _extractError;
  ExtractionResult? _extraction;

  // Build.
  final _sources = _ContextSources();
  final _extraController = TextEditingController();
  final _nameController = TextEditingController();
  bool _building = false;
  String? _buildError;
  LorebookBuildException? _buildDebug;
  Lorebook? _built;
  List<Map<String, String>>? _previewMessages;
  Timer? _timer;
  int _elapsed = 0;

  /// The character's **closed** lorebooks: attached books that couldn't be
  /// downloaded whole (private, or an inaccessible advanced script). These are
  /// recovered by capturing the assembled prompt and rebuilding it with the LLM.
  /// Public JSON books and public "advanced" (JS) books are excluded — those are
  /// downloadable and live under the Public section. Matches JAR's
  /// `renderPublicBooks` private grouping (`!accessible && !isJs`).
  List<PublicLorebook> get _closedBooks =>
      _public.where((b) => !b.accessible && !b.isJs).toList();

  /// Whether closed-lorebook extraction is currently possible: the user opted in
  /// and is logged into Janitor.AI, and no capture is already running.
  bool get _canRebuild {
    final loggedIn = ref.watch(janitorAccountProvider).isLoggedIn;
    final enabled =
        ref.watch(appSettingsProvider).value?.extractJanitorLocally ?? false;
    return loggedIn && enabled && !_extracting;
  }

  /// The character lists at least one "advanced" (Nine API / JS) lorebook. Those
  /// inject their entries inline, so the content can't be separated mechanically
  /// — it must be mined from the full captured prompt with the LLM. When true the
  /// heuristic "extracted content" + "download txt" path is dropped (it would be
  /// misleading) and the build goes straight through the LLM.
  bool get _hasAdvanced => hasAdvancedLorebook(widget.args.meta);

  /// Id of the JS lorebook currently being rebuilt by the LLM (per-row spinner).
  String? _jsBuildingId;

  @override
  void initState() {
    super.initState();
    _loadPublic();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _extraController.dispose();
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
    GlazeBottomSheet.show<void>(
      context,
      items: [
        BottomSheetItem(
          icon: Icons.bookmark_add_outlined,
          label: 'Save to Glaze',
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await _saveLorebook(book.toLorebook());
          },
        ),
        BottomSheetItem(
          icon: Icons.download_outlined,
          label: 'Export .json (SillyTavern)',
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
    GlazeBottomSheet.show<void>(
      context,
      title: 'Scripted lorebook',
      bigInfo: BottomSheetBigInfo(
        icon: Icons.code_rounded,
        description:
            "This is an advanced (scripted) lorebook. Its entries are generated "
            "by JavaScript, so it can't be downloaded as-is — it has to be sent "
            "to your active LLM to be rebuilt into keyed World Info entries.",
        buttonText: 'Rebuild with LLM',
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
    setState(() => _jsBuildingId = book.id);
    try {
      final lb = await ref
          .read(janitorExtractorProvider)
          .buildLorebookFromJs(
            jsSource: book.jsSource,
            name: book.title.isNotEmpty ? book.title : 'Janitor Lorebook',
            meta: widget.args.meta,
          );
      if (!mounted) return;
      setState(() => _jsBuildingId = null);
      _offerSaveExport(lb);
    } catch (e) {
      if (!mounted) return;
      setState(() => _jsBuildingId = null);
      GlazeToast.show(context, 'Build failed: $e');
    }
  }

  /// Bottom sheet offering Save-to-Glaze / Export-.json for a built [Lorebook].
  void _offerSaveExport(Lorebook book) {
    GlazeBottomSheet.show<void>(
      context,
      items: [
        BottomSheetItem(
          icon: Icons.bookmark_add_outlined,
          label: 'Save to Glaze',
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await _saveLorebook(book);
          },
        ),
        BottomSheetItem(
          icon: Icons.download_outlined,
          label: 'Export .json (SillyTavern)',
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
          'Saved "${book.name}" (${book.entries.length} entries)',
        );
      }
    } catch (e) {
      if (mounted) GlazeToast.show(context, 'Save failed: $e');
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
      if (mounted) GlazeToast.show(context, 'Exported $name.json');
    } catch (e) {
      if (mounted) GlazeToast.show(context, 'Export failed: $e');
    }
  }

  // ─── Closed-lorebook extraction + build ─────────────────────────────────────

  /// Rebuild **all** the character's closed lorebooks in one pass. The capture
  /// step assembles the character's full prompt through the Janitor.AI session
  /// (not a single book), so every closed book is recovered together and merged
  /// into one — a single action covers them all, no per-row button.
  Future<void> _extractAll() async {
    if (_extracting) return;
    setState(() {
      _extracting = true;
      _extractError = null;
      _extractPhase = null;
      _extraction = null;
      _built = null;
      _previewMessages = null;
      _buildError = null;
      _buildDebug = null;
    });
    try {
      final result = await ref
          .read(janitorExtractorProvider)
          .extract(
            widget.args.sourceUrl,
            onPhase: (p) {
              if (mounted) setState(() => _extractPhase = p);
            },
          );
      if (!mounted) return;
      setState(() {
        _extraction = result;
        if (_nameController.text.trim().isEmpty) {
          _nameController.text =
              '${result.character.charData.name} — Closed Lorebook';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _extractError = e.toString());
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
    final fromFull = ex.hasAdvancedLorebook;
    try {
      final book = await ref
          .read(janitorExtractorProvider)
          .buildLorebook(
            lorebookText: fromFull ? ex.fullPromptText : ex.lorebookText,
            name: _nameController.text.trim().isEmpty
                ? '${ex.character.charData.name} — Closed Lorebook'
                : _nameController.text.trim(),
            card: _sources.card ? ex.cardContext : '',
            catalog: _sources.catalog ? ex.catalogContext : '',
            scenario: _sources.scenario ? ex.scenarioContext : '',
            greetings: _sources.greetings ? ex.greetingsContext : '',
            lorebookDescs: _sources.lorebookDescs
                ? ex.lorebookDescsContext
                : '',
            extra: _sources.extra ? _extraController.text.trim() : '',
            fromFullPrompt: fromFull,
          );
      if (mounted) setState(() => _built = book);
    } catch (e) {
      if (mounted) {
        setState(() {
          _buildError = e.toString();
          _buildDebug = e is LorebookBuildException ? e : null;
        });
      }
    } finally {
      _timer?.cancel();
      if (mounted) setState(() => _building = false);
    }
  }

  void _preview() {
    final ex = _extraction;
    if (ex == null) return;
    final fromFull = ex.hasAdvancedLorebook;
    setState(() {
      _previewMessages = buildLorebookMessages(
        fromFull ? ex.fullPromptText : ex.lorebookText,
        card: _sources.card ? ex.cardContext : '',
        catalog: _sources.catalog ? ex.catalogContext : '',
        scenario: _sources.scenario ? ex.scenarioContext : '',
        greetings: _sources.greetings ? ex.greetingsContext : '',
        lorebookDescs: _sources.lorebookDescs ? ex.lorebookDescsContext : '',
        extra: _sources.extra ? _extraController.text.trim() : '',
        fromFullPrompt: fromFull,
      );
    });
  }

  /// Export the isolated lorebook text verbatim as a plain .txt file. Without an
  /// LLM the real entry boundaries and trigger keys can't be recovered, so we hand
  /// back the extracted content as-is for manual use rather than a keyless,
  /// over-segmented lorebook.
  Future<void> _downloadExtracted() async {
    final ex = _extraction;
    if (ex == null) return;
    final text = ex.lorebookText.trim();
    if (text.isEmpty) {
      GlazeToast.show(context, 'No lorebook text to download.');
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
      if (mounted) GlazeToast.show(context, 'Exported $name.txt');
    } catch (e) {
      if (mounted) GlazeToast.show(context, 'Export failed: $e');
    }
  }

  // ─── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final closed = _closedBooks;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PublicSection(
            loading: _loadingPublic,
            books: _public,
            onDownload: _downloadPublic,
            onDownloadJs: _downloadJs,
            buildingId: _jsBuildingId,
          ),
          // Closed / private lorebooks live at the very end: each is shown with a
          // Rebuild button and a "must be rebuilt from prompt" hint, and the
          // rebuild captures the assembled prompt + runs the LLM build below.
          if (!_loadingPublic && closed.isNotEmpty) ...[
            const SizedBox(height: 20),
            _buildClosedSection(cs, closed),
          ],
        ],
      ),
    );
  }

  Widget _buildClosedSection(ColorScheme cs, List<PublicLorebook> closed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle('Closed lorebooks', cs: cs),
        const SizedBox(height: 4),
        Text(
          'These lorebooks are private — they can only be recovered by capturing '
          'the assembled prompt through your Janitor.AI session and rebuilding it '
          'into keyed entries with your active LLM. Multiple closed lorebooks are '
          'merged into one.',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        if (_hasAdvanced) ...[
          const SizedBox(height: 8),
          _AdvancedNotice(cs: cs),
        ],
        const SizedBox(height: 10),
        for (final b in closed) ...[
          _ClosedRow(book: b),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 4),
        // A single action for every closed book: the capture assembles the whole
        // prompt at once, so all closed lorebooks are rebuilt together (not one
        // per row).
        _RebuildAllButton(
          count: closed.length,
          rebuilding: _extracting,
          onRebuild: _canRebuild ? _extractAll : null,
          cs: cs,
        ),
        const SizedBox(height: 8),
        _buildExtractStatus(cs),
        if (_extraction != null) ...[
          const SizedBox(height: 16),
          _buildBuildBlock(cs),
        ],
      ],
    );
  }

  /// Why the Rebuild button is disabled (opt-in / login) plus the live capture
  /// phase and any capture error. The single Rebuild action for all closed
  /// lorebooks lives just above.
  Widget _buildExtractStatus(ColorScheme cs) {
    final loggedIn = ref.watch(janitorAccountProvider).isLoggedIn;
    final enabled =
        ref.watch(appSettingsProvider).value?.extractJanitorLocally ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!enabled)
          _Hint(
            'Enable "Extract lorebooks and characters locally using Janitor.AI '
            'account" in Settings to rebuild closed lorebooks.',
            cs: cs,
          )
        else if (!loggedIn)
          _Hint('Log in to Janitor.AI (catalog menu) to rebuild.', cs: cs),
        if (_extracting && _extractPhase != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: cs.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _extractPhase!,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
        if (_extractError != null) ...[
          const SizedBox(height: 8),
          Text(
            _extractError!,
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildBuildBlock(ColorScheme cs) {
    final ex = _extraction!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ex.hasAdvancedLorebook
                ? 'Advanced (JS) lorebook — its entries are injected inline, so '
                      'the full prompt (${estimateTokens(ex.fullPromptText)} '
                      'tokens) is mined with the LLM.'
                : ex.hasLorebook
                ? 'Extracted content · ${estimateTokens(ex.lorebookText)} tokens'
                : 'No closed lorebook text was found.',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          if (ex.hasExtractable) ...[
            // For an advanced lorebook the heuristic "extracted content" is
            // meaningless (the entries are inline), so skip the txt-download path
            // and go straight to the LLM build.
            if (ex.hasLorebook && !ex.hasAdvancedLorebook) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _downloadExtracted,
                icon: const Icon(Icons.notes_rounded, size: 16),
                label: const Text('Download extracted content as txt'),
              ),
              const _OrDivider(),
            ] else
              const SizedBox(height: 12),
            _SectionTitle('Build with LLM', cs: cs),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              style: TextStyle(fontSize: 13, color: cs.onSurface),
              decoration: _fieldDecoration(cs, 'World info name (optional)'),
            ),
            const SizedBox(height: 12),
            Text(
              'Context sent for key inference (never output as entries). '
              'Tap a block to see exactly what will be sent:',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            _contextBlocks(cs, ex),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _building ? null : _build,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cs.primary,
                    foregroundColor: cs.onPrimary,
                  ),
                  child: _building
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('Building… ${_elapsed}s'),
                          ],
                        )
                      : const Text('Build lorebook'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: _building ? null : _preview,
                  child: const Text('Preview prompt'),
                ),
              ],
            ),
            if (_buildError != null) ...[
              const SizedBox(height: 8),
              Text(
                _buildError!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
            if (_buildDebug != null) ...[
              const SizedBox(height: 8),
              _LlmDebugPanel(error: _buildDebug!, cs: cs),
            ],
            if (_previewMessages != null) ...[
              const SizedBox(height: 12),
              _PromptPreview(messages: _previewMessages!, cs: cs),
            ],
            if (_built != null) ...[
              const SizedBox(height: 12),
              _buildResult(cs, _built!),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildResult(ColorScheme cs, Lorebook book) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Built ${book.entries.length} entries',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: () => _saveLorebook(book),
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                ),
                icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                label: const Text('Save to Glaze'),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    _exportJson(glazeLorebookToTavernJson(book), book.name),
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Export .json'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _JsonView(
            json: const JsonEncoder.withIndent(
              '  ',
            ).convert(glazeLorebookToTavernJson(book)),
            cs: cs,
          ),
        ],
      ),
    );
  }

  /// Context sources rendered as collapsible blocks: each keeps its on/off
  /// toggle but also reveals the exact text that will be sent to the build LLM
  /// (the recovered card, the catalog/scenario/greetings, the public lorebook
  /// descriptions). A source with no content is shown disabled with a
  /// "Content is empty" hint; custom text is always available (the user types
  /// it).
  Widget _contextBlocks(ColorScheme cs, ExtractionResult ex) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ContextBlock(
          label: 'Character card',
          content: ex.cardContext,
          value: _sources.card,
          onChanged: (v) => setState(() => _sources.card = v),
          cs: cs,
        ),
        _ContextBlock(
          label: 'Card description on site',
          content: ex.catalogContext,
          value: _sources.catalog,
          onChanged: (v) => setState(() => _sources.catalog = v),
          cs: cs,
        ),
        _ContextBlock(
          label: 'Scenario',
          content: ex.scenarioContext,
          value: _sources.scenario,
          onChanged: (v) => setState(() => _sources.scenario = v),
          cs: cs,
        ),
        _ContextBlock(
          label: 'First message(s)',
          content: ex.greetingsContext,
          value: _sources.greetings,
          onChanged: (v) => setState(() => _sources.greetings = v),
          cs: cs,
        ),
        _ContextBlock(
          label: 'Lorebook descriptions',
          content: ex.lorebookDescsContext,
          value: _sources.lorebookDescs,
          onChanged: (v) => setState(() => _sources.lorebookDescs = v),
          cs: cs,
        ),
        _CustomContextBlock(
          value: _sources.extra,
          controller: _extraController,
          onChanged: (v) => setState(() => _sources.extra = v),
          decoration: _fieldDecoration(cs, 'Optional custom context…'),
          cs: cs,
        ),
      ],
    );
  }

  InputDecoration _fieldDecoration(ColorScheme cs, String hint) =>
      InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        filled: true,
        fillColor: cs.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      );
}

// ─── Sub-widgets ──────────────────────────────────────────────────────────────

class _PublicSection extends StatelessWidget {
  final bool loading;
  final List<PublicLorebook> books;
  final void Function(PublicLorebook) onDownload;
  final void Function(PublicLorebook) onDownloadJs;
  final String? buildingId;
  const _PublicSection({
    required this.loading,
    required this.books,
    required this.onDownload,
    required this.onDownloadJs,
    required this.buildingId,
  });

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    if (loading) {
      return Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Text(
            'Loading lorebooks…',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      );
    }
    // Everything downloadable goes under the single "Public lorebooks" headline:
    //  - JSON books map 1:1 and download whole (no LLM);
    //  - "advanced" / Nine API books are public but shipped as a script, so their
    //    download opens a rebuild explanation and is converted with the LLM.
    // Private/locked books are NOT shown here — they belong to the closed section.
    final json = books.where((b) => b.accessible && !b.isJs).toList();
    final js = books.where((b) => b.isJs).toList();
    if (json.isEmpty && js.isEmpty) {
      // No downloadable books. Stay silent when there are closed books (the
      // closed section carries the messaging); otherwise say there are none.
      final hasClosed = books.any((b) => !b.accessible && !b.isJs);
      if (hasClosed) return const SizedBox.shrink();
      return Text(
        'No public lorebooks attached.',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle('Public lorebooks', cs: cs),
        const SizedBox(height: 4),
        Text(
          js.isEmpty
              ? 'Downloaded whole from Janitor.AI — no LLM needed.'
              : 'Downloaded whole from Janitor.AI. Scripted (advanced) books are '
                    'rebuilt into entries with your active LLM.',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        for (final b in json) ...[
          _PublicRow(book: b, onDownload: () => onDownload(b)),
          const SizedBox(height: 8),
        ],
        for (final b in js) ...[
          _PublicRow(
            book: b,
            onDownload: () => onDownloadJs(b),
            building: buildingId == b.id,
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _PublicRow extends StatelessWidget {
  final PublicLorebook book;
  final VoidCallback? onDownload;
  final bool building;
  const _PublicRow({
    required this.book,
    this.onDownload,
    this.building = false,
  });

  IconData get _icon =>
      book.isJs ? Icons.code_rounded : Icons.menu_book_rounded;

  String get _subtitle => book.isJs
      ? 'Scripted (advanced) — rebuild with LLM'
      : '${book.entryCount} entries';

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(_icon, size: 18, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.title.isEmpty ? 'Lorebook' : book.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                Text(
                  _subtitle,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                if (book.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    book.description.trim(),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (building)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: cs.primary,
                ),
              ),
            )
          else
            IconButton(
              onPressed: onDownload,
              icon: const Icon(Icons.download_rounded, size: 20),
              color: cs.primary,
              tooltip: 'Download',
            ),
        ],
      ),
    );
  }
}

/// One **closed** (private) lorebook row: a lock icon, the title and the
/// "must be rebuilt from prompt" hint. Info-only — the rebuild action is a
/// single shared button below the list (see [_RebuildAllButton]), because the
/// capture recovers every closed book at once and merges them into one.
class _ClosedRow extends StatelessWidget {
  final PublicLorebook book;
  const _ClosedRow({required this.book});

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.title.isEmpty ? 'Lorebook' : book.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                Text(
                  'Must be rebuilt from the prompt',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                if (book.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    book.description.trim(),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.85),
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

/// The single "rebuild all closed lorebooks" action. One capture recovers every
/// closed book at once, so there is exactly one button for the whole section
/// (not one per row). Shows a spinner while the capture + LLM rebuild runs and
/// is disabled when the user hasn't opted in / logged in.
class _RebuildAllButton extends StatelessWidget {
  final int count;
  final bool rebuilding;
  final VoidCallback? onRebuild;
  final ColorScheme cs;
  const _RebuildAllButton({
    required this.count,
    required this.rebuilding,
    required this.onRebuild,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: rebuilding ? null : onRebuild,
        style: ElevatedButton.styleFrom(
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        icon: rebuilding
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.auto_fix_high_rounded, size: 18),
        label: Text(
          rebuilding
              ? 'Rebuilding…'
              : count > 1
              ? 'Rebuild all closed lorebooks ($count)'
              : 'Rebuild closed lorebook',
        ),
      ),
    );
  }
}

/// A context source rendered as a collapsible block: the header carries the
/// include/exclude toggle and a char count; expanding it reveals the exact text
/// that will be sent to the build LLM for this source.
class _ContextBlock extends StatelessWidget {
  final String label;
  final String content;
  final bool value;
  final ValueChanged<bool> onChanged;
  final ColorScheme cs;
  const _ContextBlock({
    required this.label,
    required this.content,
    required this.value,
    required this.onChanged,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    final text = content.trim();
    final empty = text.isEmpty;
    // An empty source can't contribute anything, so it is shown disabled with a
    // "Content is empty" hint and is not expandable.
    if (empty) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
          child: Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: false,
                  onChanged: null,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
              Text(
                'Content is empty',
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 6),
          minTileHeight: 44,
          // The Checkbox consumes its own taps, so toggling inclusion does not
          // expand/collapse the tile.
          leading: SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          title: Text(
            label,
            style: TextStyle(fontSize: 13, color: cs.onSurface),
          ),
          subtitle: Text(
            '${estimateTokens(text)} tokens',
            style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          children: [
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 180),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Custom-text context source: like [_ContextBlock] but its body is an editable
/// field (the user supplies the content rather than it being derived).
class _CustomContextBlock extends StatelessWidget {
  final bool value;
  final TextEditingController controller;
  final ValueChanged<bool> onChanged;
  final InputDecoration decoration;
  final ColorScheme cs;
  const _CustomContextBlock({
    required this.value,
    required this.controller,
    required this.onChanged,
    required this.decoration,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 6),
          minTileHeight: 44,
          initiallyExpanded: value,
          leading: SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          title: Text(
            'Custom text',
            style: TextStyle(fontSize: 13, color: cs.onSurface),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          children: [
            TextField(
              controller: controller,
              maxLines: 3,
              style: TextStyle(fontSize: 13, color: cs.onSurface),
              decoration: decoration,
            ),
          ],
        ),
      ),
    );
  }
}

class _PromptPreview extends StatelessWidget {
  final List<Map<String, String>> messages;
  final ColorScheme cs;
  const _PromptPreview({required this.messages, required this.cs});

  @override
  Widget build(BuildContext context) {
    final text = messages
        .map((m) => '### ${m['role']}\n${m['content']}')
        .join('\n\n');
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(
          'Prompt sent to the build LLM',
          style: TextStyle(fontSize: 12, color: cs.onSurface),
        ),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 240),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: cs.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
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
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        initiallyExpanded: true,
        leading: Icon(Icons.bug_report_outlined, size: 18, color: cs.primary),
        title: Text(
          'LLM response (debug)',
          style: TextStyle(fontSize: 12, color: cs.onSurface),
        ),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          for (final (label, body) in sections) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$label · ${estimateTokens(body)} tokens',
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
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 200),
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  body,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: cs.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final ColorScheme cs;
  const _SectionTitle(this.text, {required this.cs});

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: cs.onSurface,
    ),
  );
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

/// Prominent banner shown when the character has an "advanced" (JS) lorebook:
/// the content can't be separated mechanically, so it must be collected via the
/// LLM. Port of JAR's `advancedNotice` (`.hint.warn`).
class _AdvancedNotice extends StatelessWidget {
  final ColorScheme cs;
  const _AdvancedNotice({required this.cs});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: cs.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
      border: Border(left: BorderSide(color: cs.primary, width: 2)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.code_rounded, size: 16, color: cs.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'This character uses JS (advanced) lorebooks. The lorebook '
            'content must be collected with an LLM.',
            style: TextStyle(fontSize: 12, height: 1.35, color: cs.onSurface),
          ),
        ),
      ],
    ),
  );
}

/// Collapsible pretty-printed JSON of a built lorebook (SillyTavern World Info
/// shape). Port of JAR's `worldInfoPre` result block.
class _JsonView extends StatelessWidget {
  final String json;
  final ColorScheme cs;
  const _JsonView({required this.json, required this.cs});

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(
        'Lorebook JSON',
        style: TextStyle(fontSize: 12, color: cs.onSurface),
      ),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [
        Row(
          children: [
            const Spacer(),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Copy',
              icon: const Icon(Icons.copy_rounded, size: 14),
              color: cs.onSurfaceVariant,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: json));
                if (context.mounted) GlazeToast.show(context, 'Copied JSON');
              },
            ),
          ],
        ),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 240),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              json,
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: cs.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final line = Expanded(
      child: Divider(color: cs.onSurfaceVariant.withValues(alpha: 0.3)),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          line,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              'OR',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          line,
        ],
      ),
    );
  }
}
