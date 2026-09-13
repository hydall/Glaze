import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/character.dart';
import '../../core/services/chat_import_export.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../catalog/catalog_models.dart';
import '../catalog/services/janitor_provider.dart';
import '../catalog/services/janitor_public_lorebook.dart';
import '../catalog/widgets/janitor_comments_section.dart';
import '../catalog/widgets/janitor_lorebooks_tab.dart';
import '../../core/services/persona_character_converter.dart';
import '../../core/utils/html_to_markdown.dart';
import '../../core/utils/platform_paths.dart';
import '../../core/state/character_provider.dart';
import '../../core/state/chat_session_ops_provider.dart';
import '../../core/state/card_rewriter_providers.dart';
import '../../core/state/db_provider.dart';
import '../../core/services/card_rewriter/card_rewriter_contracts.dart';
import '../../core/utils/id_generator.dart';
import '../../features/chat/chat_actions_service.dart';
import '../../features/chat/widgets/session_picker_sheet.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/theme/theme_preset.dart';
import '../../shared/theme/theme_provider.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_tab_bar.dart';
import '../../shared/widgets/swipe_tab_switcher.dart';
import '../../shared/widgets/tab_slide_switcher.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/image_viewer.dart';
import '../../shared/widgets/sheet_view.dart';
import '../../shared/widgets/colored_markdown.dart';
import '../../shared/widgets/variation_chip.dart';
import '../../shared/utils/variant_label.dart';
import 'character_editor_screen.dart';
import '../character_gallery/widgets/character_gallery_view.dart';
import 'widgets/character_variations_sheet.dart';
import 'widgets/character_hiding_onboarding_sheet.dart';

// ─── Colour tokens ─────────────────────────────────────────────────────────

const _kAccentDim = Color(0x1F7996CE);
const _kAccentBorder = Color(0x337996CE);
const _kNsfw = Color(0xFFFF4444);
const _kNsfwBg = Color(0x33FF4444);
const _kNsfwBorder = Color(0x4DFF4444);
const _kSfw = Color(0xFF4CAF50);
const _kSfwBg = Color(0x334CAF50);
const _kSfwBorder = Color(0x524CAF50);
const _kSurface = Color(0x0DFFFFFF);
const _kBorderLine = Color(0x0DFFFFFF);
const _kText75 = Color(0xBFFFFFFF);
const _kText50 = Color(0x80FFFFFF);
const _kText35 = Color(0x59FFFFFF);

Border _detailHeaderBorder(BuildContext context, ThemePreset preset) {
  final base = preset.borderParsed ?? context.cs.onSurface;
  return Border.all(
    color: base.withValues(alpha: preset.borderOpacity.clamp(0.0, 1.0)),
    width: preset.borderWidth,
  );
}

// ─── Tabs ──────────────────────────────────────────────────────────────────

// Info (with comments folded in under the bio), Prompt Blocks (with lorebooks
// folded in under the prompts), and the character's image gallery.
List<GlazeTabItem> _detailTabs(BuildContext context) => [
  GlazeTabItem(label: 'section_info'.tr(), icon: Icons.info_outline_rounded),
  GlazeTabItem(
    label: 'section_prompt_blocks'.tr(),
    icon: Icons.description_outlined,
  ),
  GlazeTabItem(
    label: 'section_images'.tr(),
    icon: Icons.photo_library_outlined,
  ),
];

// ─── Screen ────────────────────────────────────────────────────────────────

class CharacterDetailSheetLauncher extends StatefulWidget {
  final String charId;
  const CharacterDetailSheetLauncher({super.key, required this.charId});

  @override
  State<CharacterDetailSheetLauncher> createState() =>
      _CharacterDetailSheetLauncherState();
}

class _CharacterDetailSheetLauncherState
    extends State<CharacterDetailSheetLauncher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _show());
  }

  Future<void> _show() async {
    final location = GoRouterState.of(context).uri.path;
    final isSubRoute =
        location.endsWith('/edit') ||
        location.endsWith('/gallery') ||
        location.startsWith('/character/${widget.charId}/rewrite/');
    if (isSubRoute) return;
    String? navTarget;
    try {
      navTarget = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        backgroundColor: Colors.transparent,
        builder: (_) => CharacterDetailScreen(charId: widget.charId),
      );
    } catch (_) {}
    if (!mounted) return;
    if (navTarget != null && navTarget.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go(navTarget!);
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/characters');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(child: GlazeSpinner()),
    );
  }
}

class CharacterDetailScreen extends ConsumerStatefulWidget {
  final String charId;

  /// When set, the screen runs in catalog preview mode: it skips the DB
  /// lookup, shows an Import FAB instead of Open Chat, and hides destructive
  /// actions like edit/delete/gallery.
  final Character? previewCharacter;
  final String? previewAvatarUrl;

  /// External URL of the character's source page (e.g. its Janitor page).
  /// When set in preview mode, an "open in browser" button replaces the
  /// three-dots actions menu in the floating header.
  final String? previewSourceUrl;

  /// External URL of the creator's profile page. When set, tapping the
  /// `@creator` label in the hero opens it in the browser.
  final String? previewAuthorUrl;

  /// JanitorAI character id used to fetch this character's comments. Set only
  /// for JanitorAI catalog previews; when non-null a "Comments" tab is shown
  /// and its pages are loaded lazily as the sheet scrolls.
  final String? janitorReviewCharId;

  /// JanitorAI catalog-preview lorebook context. When non-null a "Lorebooks"
  /// tab is shown listing public lorebooks (downloadable) and offering local
  /// extraction + LLM build of the closed lorebook.
  final JanitorLorebookArgs? janitorLorebookArgs;

  /// Runs the import in the given [CatalogImportMode], chosen via the
  /// import-options bottom sheet when the previewed character has attached
  /// lorebooks (it starts immediately in [CatalogImportMode.character] when it
  /// has none).
  final Future<void> Function({CatalogImportMode mode})? onImport;

  /// Asked once when the Import button is tapped, before the mode is chosen.
  /// Returning false aborts the tap — the source uses it to explain that this
  /// character cannot be imported the way the user expects (JanitorAI cards
  /// that forbid proxies), so the warning lands on the first tap instead of
  /// after the options sheet.
  final Future<bool> Function()? onBeforeImport;

  final bool importing;

  /// Current phase label while [importing] (e.g. local extraction progress).
  final String? importPhase;

  const CharacterDetailScreen({
    super.key,
    required this.charId,
    this.previewCharacter,
    this.previewAvatarUrl,
    this.previewSourceUrl,
    this.previewAuthorUrl,
    this.janitorReviewCharId,
    this.janitorLorebookArgs,
    this.onImport,
    this.onBeforeImport,
    this.importing = false,
    this.importPhase,
  });

  bool get isPreview => previewCharacter != null;

  @override
  ConsumerState<CharacterDetailScreen> createState() =>
      _CharacterDetailScreenState();
}

class _CharacterDetailScreenState extends ConsumerState<CharacterDetailScreen> {
  int _activeTabIndex = 0;

  /// Owns the body's scroll so we can drive lazy comment paging from the
  /// near-bottom position (see [_onScroll]).
  final ScrollController _scrollController = ScrollController();

  // ─── Comments paging state (JanitorAI previews only) ──────────────────────
  final List<JanitorReview> _comments = [];
  int _commentPage = 1;
  bool _commentsLoading = false;
  bool _commentsHasMore = true;
  Object? _commentsError;

  bool get _hasComments => widget.janitorReviewCharId != null;
  bool get _hasLorebooks => widget.janitorLorebookArgs != null;

  /// Whether the previewed character actually lists attached lorebooks (not just
  /// that it is a JanitorAI preview). Drives the import-options bottom sheet.
  bool get _previewHasLorebooks =>
      widget.janitorLorebookArgs != null &&
      lorebookScriptRefs(widget.janitorLorebookArgs!.meta).isNotEmpty;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Comments live under the Info tab (the default tab), so start paging as
    // soon as the sheet opens rather than waiting for a tab switch.
    if (_hasComments) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadMoreComments();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // Comments are folded into the Info tab (index 0); page them as it scrolls.
    if (!_hasComments || _activeTabIndex != 0) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) {
      _loadMoreComments();
    }
  }

  Future<void> _loadMoreComments() async {
    final charId = widget.janitorReviewCharId;
    if (charId == null || _commentsLoading || !_commentsHasMore) return;
    setState(() {
      _commentsLoading = true;
      _commentsError = null;
    });
    try {
      final batch = await janitorFetchReviews(charId, page: _commentPage);
      if (!mounted) return;
      setState(() {
        _comments.addAll(batch);
        // A full page means there may be more; a short page is the end.
        _commentsHasMore = batch.length >= kJanitorReviewsPageSize;
        _commentPage += 1;
        _commentsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _commentsError = e;
        _commentsLoading = false;
      });
    }
  }

  void _onTabChanged(int i) {
    setState(() => _activeTabIndex = i);
  }

  /// Pops the GlazeBottomSheet, then pops this modal sheet returning [route]
  /// so the caller (launcher / card / drawer) can navigate safely.
  void _closeSheetAndNavigate(String route) {
    final nav = Navigator.of(context, rootNavigator: true);
    nav.pop(); // pop the top-most sheet
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        nav.pop<String>(route); // pop CharacterDetailScreen modal
      }
    });
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Opens the character editor stacked ABOVE this detail sheet.
  ///
  /// The detail sheet is itself an imperative modal route (opened via
  /// `showModalBottomSheet(useRootNavigator: true)`). Routing to the editor
  /// through GoRouter (`context.push`) would insert it as a declarative *page*,
  /// which the Navigator always stacks BELOW an imperatively-pushed route — so
  /// the editor appeared underneath the sheet. Pushing it imperatively on the
  /// same root navigator puts it on top; popping it (its own back button, the
  /// system back gesture, or `context.pop`) returns to the still-open sheet.
  void _openEditor() {
    final isIos = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final editor = CharacterEditorScreen(charId: widget.charId);
    Navigator.of(context, rootNavigator: true).push(
      isIos
          ? CupertinoPageRoute<void>(builder: (_) => editor)
          : MaterialPageRoute<void>(builder: (_) => editor),
    );
  }

  void _openActionsMenu() {
    final rootNav = Navigator.of(context, rootNavigator: true);
    final char = ref.read(characterByIdProvider(widget.charId));
    final isHidden = char?.hidden ?? false;
    final catalogUrl = char?.extensions['catalogUrl'];
    final hasCatalogUrl = catalogUrl is String && catalogUrl.isNotEmpty;
    final variantCount = _variantCount(char);
    GlazeBottomSheet.show<void>(
      context,
      items: [
        BottomSheetItem(
          icon: Icons.edit_outlined,
          label: 'action_edit'.tr(),
          onTap: () {
            rootNav.pop();
            if (!mounted) return;
            _openEditor();
          },
        ),
        BottomSheetItem(
          icon: Icons.auto_fix_high_outlined,
          label: 'rewrite_entry'.tr(),
          hint: 'rewrite_entry_hint'.tr(),
          onTap: () {
            rootNav.pop();
            _startRewrite();
          },
        ),
        BottomSheetItem(
          icon: isHidden
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
          label: isHidden ? 'action_unhide'.tr() : 'action_hide'.tr(),
          onTap: () {
            rootNav.pop();
            _toggleHidden(isHidden);
          },
        ),
        BottomSheetItem(
          icon: Icons.dynamic_feed_rounded,
          label: 'variations_title'.tr(),
          // Surface the group size on the entry point itself, so the menu says
          // whether there is anything behind it before you tap.
          hint: variantCount > 1
              ? 'variations_count'.plural(variantCount)
              : 'variations_hint_single'.tr(),
          onTap: () {
            rootNav.pop();
            if (!mounted) return;
            _showVariations(context);
          },
        ),
        if (hasCatalogUrl)
          BottomSheetItem(
            icon: Icons.travel_explore_outlined,
            label: 'action_open_in_catalog'.tr(),
            onTap: () {
              rootNav.pop();
              _openExternal(catalogUrl);
            },
          ),
        BottomSheetItem(
          icon: Icons.badge_outlined,
          label: 'action_convert_to_persona'.tr(),
          onTap: () async {
            rootNav.pop();
            if (char == null || !mounted) return;
            await convertCharacterToPersona(ref, char);
            if (!mounted) return;
            GlazeToast.show(context, 'convert_to_persona_done'.tr());
          },
        ),
        BottomSheetItem(
          icon: Icons.delete_outline,
          label: 'action_delete_msg'.tr(),
          isDestructive: true,
          onTap: () {
            rootNav.pop();
            if (!mounted) return;
            _confirmDelete(context);
          },
        ),
      ],
    );
  }

  Future<void> _startRewrite() async {
    final sessions = await ref
        .read(chatSessionOpsProvider.notifier)
        .getSessionMetadataByCharacter(widget.charId);
    if (!mounted) return;
    if (sessions.isEmpty) {
      GlazeToast.show(context, 'rewrite_no_sessions'.tr());
      return;
    }
    final sessionId = await GlazeBottomSheet.show<String>(
      context,
      title: 'rewrite_choose_session'.tr(),
      items: [
        for (final session in sessions)
          BottomSheetItem(
            icon: Icons.chat_bubble_outline_rounded,
            label: 'session_name'.tr(
              namedArgs: {'id': '${session.sessionIndex + 1}'},
            ),
            hint:
                '${session.messageCount} ${'count_messages'.plural(session.messageCount)}',
            onTap: () => Navigator.of(
              context,
              rootNavigator: true,
            ).pop(session.sessionId),
          ),
      ],
    );
    if (!mounted || sessionId == null) return;
    final instruction = await GlazeBottomSheet.show<String>(
      context,
      title: 'rewrite_instruction_title'.tr(),
      input: BottomSheetInput(
        placeholder: 'rewrite_instruction_hint'.tr(),
        confirmLabel: 'rewrite_start'.tr(),
        onConfirm: (value) =>
            Navigator.of(context, rootNavigator: true).pop(value),
      ),
    );
    if (!mounted || instruction == null) return;
    final requestKey = 'rewrite-${generateId()}';
    final created = await ref
        .read(manualRewriteJobRepoProvider)
        .createOrGet(
          requestKey: requestKey,
          chatSessionId: sessionId,
          characterId: widget.charId,
          requestJson: jsonEncode({
            'field': CardRewriteField.description.wireName,
            'instruction': instruction,
          }),
        );
    unawaited(
      ref
          .read(manualRewriteServiceProvider)
          .run(
            requestKey: requestKey,
            chatSessionId: sessionId,
            characterId: widget.charId,
            field: CardRewriteField.description,
            instruction: instruction,
          ),
    );
    if (!mounted) return;
    // Return a route to the imperative sheet launcher. It closes the detail
    // sheet before GoRouter installs the durable review route on the root.
    Navigator.of(
      context,
      rootNavigator: true,
    ).pop<String>('/character/${widget.charId}/rewrite/${created.job.id}');
  }

  void _confirmDelete(BuildContext context) async {
    final char = widget.isPreview
        ? widget.previewCharacter
        : ref.read(characterByIdProvider(widget.charId));
    if (char == null) return;
    if (!context.mounted) return;

    final rootNav = Navigator.of(context, rootNavigator: true);
    unawaited(
      GlazeBottomSheet.show<void>(
        context,
        title: 'action_delete_char'.tr(),
        bigInfo: BottomSheetBigInfo(
          icon: Icons.delete_outline,
          description:
              '${'confirm_delete_character'.tr().replaceAll('?', '')} "${char.displayName?.trim().isNotEmpty == true ? char.displayName!.trim() : char.name}"?',
        ),
        items: [
          BottomSheetItem(
            label: 'action_delete_msg'.tr(),
            isDestructive: true,
            centered: true,
            onTap: () async {
              await ref.read(charactersProvider.notifier).remove(char.id);
              if (!context.mounted) return;
              _closeSheetAndNavigate('/characters');
            },
          ),
          BottomSheetItem(
            label: 'btn_cancel'.tr(),
            centered: true,
            onTap: () => rootNav.pop(),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleHidden(bool wasHidden) async {
    await ref
        .read(charactersProvider.notifier)
        .setHidden(widget.charId, !wasHidden);
    if (!mounted) return;
    GlazeToast.show(
      context,
      wasHidden ? 'char_unhidden_toast'.tr() : 'char_hidden_toast'.tr(),
    );
    if (!wasHidden) {
      await maybeShowCharacterHidingOnboarding(context);
    }
  }

  /// Label of the variation this sheet shows, or null when the character has no
  /// variations and there is nothing to disambiguate — same rule as the card.
  String? _variationLabelOf(Character char) =>
      _variantCount(char) > 1 ? variantLabel(char) : null;

  /// Number of variations in [char]'s group (1 for a standalone character).
  int _variantCount(Character? char) {
    if (char == null) return 1;
    final groupId = char.variantGroupId.isEmpty ? char.id : char.variantGroupId;
    return ref.read(variantGroupStatsProvider).value?[groupId]?.count ?? 1;
  }

  /// Opens the variations grid for this character's group. Picking a card there
  /// opens that variation's own sheet on top of this one, so nothing comes back.
  void _showVariations(BuildContext context) {
    final char = ref.read(characterByIdProvider(widget.charId));
    final groupId = (char == null || char.variantGroupId.isEmpty)
        ? widget.charId
        : char.variantGroupId;
    showCharacterVariationsSheet(
      context,
      groupId: groupId,
      sourceId: widget.charId,
    );
  }

  /// Import FAB tap. When the previewed character ships attached lorebooks the
  /// user first picks what to pull; otherwise the import starts immediately.
  Future<void> _handleImportTap() async {
    if (widget.importing) return;
    final gate = widget.onBeforeImport;
    if (gate != null && !await gate()) return;
    if (!mounted) return;
    if (_previewHasLorebooks) {
      _showImportOptions();
    } else {
      await widget.onImport?.call(mode: CatalogImportMode.character);
    }
  }

  void _showImportOptions() {
    final rootNav = Navigator.of(context, rootNavigator: true);
    void run(CatalogImportMode mode) {
      rootNav.pop();
      widget.onImport?.call(mode: mode);
    }

    GlazeBottomSheet.show<void>(
      context,
      title: 'catalog_import_options_title'.tr(),
      items: [
        BottomSheetItem(
          icon: Icons.auto_stories_outlined,
          label: 'catalog_import_with_lorebooks'.tr(),
          hint: 'catalog_import_with_lorebooks_hint'.tr(),
          onTap: () => run(CatalogImportMode.characterAndLorebooks),
        ),
        BottomSheetItem(
          icon: Icons.person_outline_rounded,
          label: 'catalog_import_char_only'.tr(),
          hint: 'catalog_import_char_only_hint'.tr(),
          onTap: () => run(CatalogImportMode.character),
        ),
        // Lorebooks on their own: the character is already in the library (or
        // the user only wants the world info), so nothing is added to it.
        BottomSheetItem(
          icon: Icons.menu_book_outlined,
          label: 'catalog_import_lorebooks_only'.tr(),
          hint: 'catalog_import_lorebooks_only_hint'.tr(),
          onTap: () => run(CatalogImportMode.lorebooks),
        ),
      ],
    );
  }

  /// Opens a chat with [cId], asking only which *session* to open.
  ///
  /// It no longer asks which variation: this sheet now belongs to exactly one
  /// variation (the library opens the variations grid first, and picking a card
  /// there opens that variation's sheet), so a prompt here would be the same
  /// question twice.
  Future<void> _openChat(BuildContext context, String cId) async {
    // The same picker the magic drawer opens — see `showSessionPickerSheet`.
    // This sheet used to list bare "Session #N" entries with a message count
    // and no name, preview, time or actions, which made the same list look
    // like two different features depending on where you opened it.
    //
    // The picker resolves after its own route is gone; the outer
    // CharacterDetailScreen modal is popped exactly once afterwards. Two
    // chained Navigator.pop() calls (one immediate + one via
    // addPostFrameCallback) race against the inner sheet's exit animation and
    // can drop the route on the floor.
    final result = await showSessionPickerSheet(context, charId: cId);
    if (result == null || !context.mounted) return;

    if (result.action == SessionPickerAction.importChat) {
      unawaited(_importChat(cId));
      return;
    }

    final String route;
    if (result.action == SessionPickerAction.newSession) {
      // `?new=1` asks the chat screen to *add* a session; a character with none
      // yet gets its first one from the plain route instead. Re-read the count
      // here rather than before the sheet — the picker can delete sessions.
      final hasSessions =
          (await ref
                  .read(chatSessionOpsProvider.notifier)
                  .getSessionMetadataByCharacter(cId))
              .isNotEmpty;
      if (!context.mounted) return;
      route = hasSessions ? '/chat/$cId?new=1' : '/chat/$cId';
    } else {
      route = '/chat/$cId?session=${result.session!.sessionIndex}';
    }
    Navigator.of(context, rootNavigator: true).pop<String>(route);
  }

  Future<void> _importChat(String charId) async {
    final result = await FilePicker.pickFiles(
      type: Platform.isIOS ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isIOS ? null : ['jsonl', 'json'],
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final filePath = file.path;
    try {
      ChatImportSaveResult saveResult;
      if (file.bytes != null) {
        final importResult = importChatFromJsonlString(
          utf8.decode(file.bytes!),
        );
        saveResult = await ref
            .read(chatActionsServiceProvider)
            .importChatFromResult(charId, importResult);
      } else if (filePath != null) {
        saveResult = await ref
            .read(chatActionsServiceProvider)
            .importChat(charId, filePath);
      } else {
        return;
      }
      if (!mounted) return;
      final count = saveResult.count;
      final sessionIndex = saveResult.sessionIndex;
      GlazeToast.show(
        context,
        count == 0 ? 'no_results'.tr() : 'import_success'.tr(),
      );
      if (count > 0 && sessionIndex != null) {
        // The inner "Open chat" sheet was already popped (with the value
        // 'import') before _importChat ran, so only the outer
        // CharacterDetailScreen modal remains. Pop it once, returning the chat
        // route so the launcher (_showDetailSheet) navigates via context.go.
        // Using _closeSheetAndNavigate here popped twice — the first pop closed
        // the modal with a null result, so the launcher never navigated and the
        // chat opened as a blank dark screen.
        Navigator.of(
          context,
          rootNavigator: true,
        ).pop<String>('/chat/$charId?session=$sessionIndex');
      }
    } catch (e) {
      if (mounted) {
        GlazeErrorDialog.show(
          context,
          e,
          prefix: '${'settings_err_failed'.tr()} ',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final charactersAsync = widget.isPreview
        ? const AsyncData<List<Character>>(<Character>[])
        : ref.watch(charactersProvider);
    final char = widget.isPreview
        ? widget.previewCharacter
        : ref.watch(characterByIdProvider(widget.charId));

    return SheetView(
      floating: _buildFloatingHeader(char),
      bodyPadding: EdgeInsets.zero,
      body: _buildBody(charactersAsync, char),
      floatingActionButton: char == null
          ? null
          : widget.isPreview
          ? _ImportFab(
              importing: widget.importing,
              phase: widget.importPhase,
              onTap: _handleImportTap,
            )
          : _ChatFab(onTap: () => _openChat(context, char.id)),
    );
  }

  Widget _buildBody(
    AsyncValue<List<Character>> charactersAsync,
    Character? char,
  ) {
    if (!widget.isPreview && charactersAsync.isLoading && char == null) {
      return const Center(child: GlazeSpinner());
    }
    if (char == null) {
      return Center(
        child: Text(
          'no_results'.tr(),
          style: TextStyle(color: context.cs.onSurface),
        ),
      );
    }
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final tabs = _detailTabs(context);
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HeroSection(
              character: char,
              previewAvatarUrl: widget.previewAvatarUrl,
              authorUrl: widget.previewAuthorUrl,
              onOpenAuthor: _openExternal,
              variationLabel: _variationLabelOf(char),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: GlazeTabBar(
                tabs: tabs,
                activeIndex: _activeTabIndex,
                onChanged: _onTabChanged,
              ),
            ),
            SwipeTabSwitcher(
              index: _activeTabIndex,
              length: tabs.length,
              onChanged: _onTabChanged,
              child: TabSlideSwitcher(
                index: _activeTabIndex,
                child: _buildTabContent(char),
              ),
            ),
            SizedBox(height: 100 + safeBottom),
          ],
        ),
      ),
    );
  }

  Widget _buildTabContent(Character char) {
    if (_activeTabIndex == 2) {
      // Gallery. In preview mode the character is not in the DB, so the entries
      // come from the in-memory card instead of a query that would find nothing.
      return KeyedSubtree(
        key: const ValueKey('gallery'),
        child: CharacterGalleryView(
          charId: widget.charId,
          shrinkWrap: true,
          entries: widget.isPreview ? char.gallery : null,
        ),
      );
    }
    if (_activeTabIndex == 0) {
      // Info tab: bio/tags, with the character's comments folded in below it.
      return KeyedSubtree(
        key: const ValueKey('info'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoTab(character: char),
            if (_hasComments) ...[
              _TabSectionHeader(
                icon: Icons.forum_outlined,
                label: 'section_comments'.tr(),
              ),
              JanitorCommentsView(
                comments: _comments,
                loading: _commentsLoading,
                hasMore: _commentsHasMore,
                error: _commentsError,
                onRetry: _loadMoreComments,
              ),
            ],
          ],
        ),
      );
    }
    // Prompt Blocks tab: prompt accordions, with the lorebooks folded in below.
    return KeyedSubtree(
      key: const ValueKey('prompts'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PromptsTab(character: char),
          if (_hasLorebooks) ...[
            _TabSectionHeader(
              icon: Icons.menu_book_outlined,
              label: 'section_lorebooks'.tr(),
            ),
            JanitorLorebooksTab(args: widget.janitorLorebookArgs!),
          ],
        ],
      ),
    );
  }

  Widget _buildFloatingHeader(Character? char) {
    final safeTop = MediaQueryData.fromView(View.of(context)).padding.top;
    return IgnorePointer(
      ignoring: char == null,
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(top: safeTop + 12, left: 16, right: 16),
          child: Row(
            children: [
              _DetailHeaderButton(
                icon: Icons.arrow_back,
                onTap: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/characters');
                  }
                },
              ),
              const Spacer(),
              if (!widget.isPreview && char != null)
                _DetailHeaderButton(
                  icon: Icons.more_vert_rounded,
                  onTap: _openActionsMenu,
                )
              else if (widget.isPreview &&
                  char != null &&
                  widget.previewSourceUrl != null)
                _DetailHeaderButton(
                  icon: Icons.open_in_new_rounded,
                  onTap: () => _openExternal(widget.previewSourceUrl!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Chat FAB ──────────────────────────────────────────────────────────────

class _ChatFab extends StatelessWidget {
  final VoidCallback onTap;
  const _ChatFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: context.cs.primary,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(blurRadius: 16, color: Color(0x80000000)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.chat_bubble_rounded,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              'btn_open_chat'.tr(),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportFab extends StatelessWidget {
  final bool importing;
  final String? phase;
  final VoidCallback onTap;
  const _ImportFab({required this.importing, this.phase, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: importing ? null : onTap,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: importing
              ? context.cs.primary.withValues(alpha: 0.5)
              : context.cs.primary,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(blurRadius: 16, color: Color(0x80000000)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (importing)
              const SizedBox(
                width: 18,
                height: 18,
                child: GlazeSpinner(color: Colors.white),
              )
            else
              const Icon(Icons.download_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(
              importing && phase != null && phase!.isNotEmpty
                  ? phase!
                  : 'catalog_import'.tr(),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Hero ──────────────────────────────────────────────────────────────────

class _DetailHeaderButton extends ConsumerStatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _DetailHeaderButton({required this.icon, this.onTap});

  @override
  ConsumerState<_DetailHeaderButton> createState() =>
      _DetailHeaderButtonState();
}

class _DetailHeaderButtonState extends ConsumerState<_DetailHeaderButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
      reverseDuration: const Duration(milliseconds: 150),
    );
    _scale = Tween<double>(
      begin: 1.0,
      end: 0.82,
    ).animate(CurvedAnimation(parent: _press, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preset = ref.watch(themeProvider.select((s) => s.activePreset));
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: widget.onTap != null ? (_) => _press.forward() : null,
      onTapUp: widget.onTap != null ? (_) => _press.reverse() : null,
      onTapCancel: widget.onTap != null ? () => _press.reverse() : null,
      child: ScaleTransition(
        scale: _scale,
        child: SizedBox(
          width: 40,
          height: 40,
          child: GlassSurface(
            borderRadius: BorderRadius.circular(20),
            tint: context.cs.surface,
            border: _detailHeaderBorder(context, preset),
            child: Center(
              child: Icon(widget.icon, color: context.cs.primary, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroSection extends StatelessWidget {
  final Character character;
  final String? previewAvatarUrl;
  final String? authorUrl;
  final void Function(String url)? onOpenAuthor;

  /// Name of the variation this sheet belongs to, or null when the character
  /// has none. Shown as a plain chip above the name, mirroring the card you
  /// arrived from; it is a label, not a control — the sheet is already the
  /// variation it names.
  final String? variationLabel;

  const _HeroSection({
    required this.character,
    this.previewAvatarUrl,
    this.authorUrl,
    this.onOpenAuthor,
    this.variationLabel,
  });

  String get _displayName {
    final displayName = character.displayName?.trim();
    return (displayName != null && displayName.isNotEmpty)
        ? displayName
        : character.name;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 310,
      width: double.infinity,
      child: GestureDetector(
        onTap: () {
          ImageProvider? provider;
          if (previewAvatarUrl != null && previewAvatarUrl!.isNotEmpty) {
            provider = CachedNetworkImageProvider(previewAvatarUrl!);
          } else if (character.avatarPath != null &&
              character.avatarPath!.isNotEmpty) {
            provider = FileImage(
              File(resolveGlazeFilePath(character.avatarPath!)!),
            );
          }
          if (provider != null) {
            ImageViewer.show(
              context,
              imageProvider: provider,
              description: _displayName,
            );
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildImage(),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.35, 0.60, 1.0],
                  colors: [
                    Colors.transparent,
                    Color(0x33000000),
                    Color(0xBF000000),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (variationLabel != null) ...[
                    VariationChip(name: variationLabel!, maxWidth: 180),
                    const SizedBox(height: 6),
                  ],
                  _HeroName(name: _displayName),
                  if (character.creator != null &&
                      character.creator!.isNotEmpty)
                    _buildAuthorLabel(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuthorLabel(BuildContext context) {
    final hasLink =
        authorUrl != null && authorUrl!.isNotEmpty && onOpenAuthor != null;
    final label = Text(
      '@${character.creator}',
      style: TextStyle(
        fontSize: 13,
        color: hasLink ? context.cs.primary : _kText50,
        fontWeight: hasLink ? FontWeight.w600 : FontWeight.w400,
        shadows: const [Shadow(blurRadius: 3, color: Color(0xCC000000))],
      ),
    );
    if (!hasLink) return label;
    return GestureDetector(
      onTap: () => onOpenAuthor!(authorUrl!),
      behavior: HitTestBehavior.opaque,
      child: label,
    );
  }

  Widget _buildImage() {
    if (previewAvatarUrl != null && previewAvatarUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: previewAvatarUrl!,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        placeholder: (_, _) => _HeroPlaceholder(name: _displayName),
        errorWidget: (_, _, _) => _HeroPlaceholder(name: _displayName),
      );
    }
    if (character.avatarPath != null && character.avatarPath!.isNotEmpty) {
      return Image.file(
        File(resolveGlazeFilePath(character.avatarPath!)!),
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        errorBuilder: (_, _, _) => _HeroPlaceholder(name: _displayName),
      );
    }
    return _HeroPlaceholder(name: _displayName);
  }
}

/// The character's name over the hero image.
///
/// The caption column is pinned to the *bottom* of a fixed-height image, so
/// every extra line a long name wraps onto pushes the name upward — past the
/// top of the hero and under the back button. This caps it at
/// [_kHeroNameMaxLines] and, when the name needs more room than that, scrolls
/// it from the top to the bottom and starts over instead of growing.
class _HeroName extends StatefulWidget {
  final String name;

  const _HeroName({required this.name});

  @override
  State<_HeroName> createState() => _HeroNameState();
}

const _kHeroNameMaxLines = 2;
const _kHeroNameStyle = TextStyle(
  fontSize: 22,
  fontWeight: FontWeight.w700,
  color: Colors.white,
  shadows: [Shadow(blurRadius: 6, color: Color(0xCC000000))],
);

/// How long the name rests at each end before the next leg of the loop.
const _kHeroNameHold = Duration(milliseconds: 1600);

/// Scroll speed, in logical pixels per second. Slow enough to read.
const _kHeroNameSpeed = 26.0;

/// Where the name sits in its loop after [elapsedMs]: held at the top for
/// [holdMs], scrolled down over [scrollMs], held at the bottom for another
/// [holdMs], then back to the top. Returns the distance scrolled, from 0 to
/// [overflow].
double heroNameScrollOffset({
  required double elapsedMs,
  required double overflow,
  required double holdMs,
  required double scrollMs,
}) {
  if (overflow <= 0 || scrollMs <= 0) return 0;
  final t = elapsedMs % (holdMs * 2 + scrollMs);
  if (t < holdMs) return 0;
  if (t >= holdMs + scrollMs) return overflow;
  return overflow * ((t - holdMs) / scrollMs);
}

class _HeroNameState extends State<_HeroName>
    with SingleTickerProviderStateMixin {
  late final _ticker = createTicker(_onTick);

  /// Milliseconds since the ticker started. A plain notifier rather than
  /// setState: the offset changes every frame and nothing else in the hero
  /// needs to rebuild for it.
  final ValueNotifier<double> _elapsedMs = ValueNotifier(0);

  void _onTick(Duration elapsed) {
    _elapsedMs.value = elapsed.inMicroseconds / 1000.0;
  }

  /// Whether the name is long enough to scroll is known only once it has been
  /// laid out, so the ticker is started (and stopped again) after the frame
  /// that measured it rather than from [initState].
  void _setTicking(bool ticking) {
    if (ticking == _ticker.isActive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ticking == _ticker.isActive) return;
      if (ticking) {
        _ticker.start();
      } else {
        _ticker.stop();
        _elapsedMs.value = 0;
      }
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsedMs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A reader who has asked the platform to reduce motion gets the name
    // clipped to the same height instead — still better than a name climbing
    // off the top of the image. Battery Saver is deliberately *not* consulted:
    // it defaults to on, so honouring it here would leave the overflowing name
    // unreadable for almost everyone, and this ticker only runs while a sheet
    // whose name actually overflows is on screen.
    final animate = !MediaQuery.disableAnimationsOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.name, style: _kHeroNameStyle),
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final viewport = painter.preferredLineHeight * _kHeroNameMaxLines;
        final overflow = painter.height - viewport;
        painter.dispose();

        final text = Text(widget.name, style: _kHeroNameStyle);
        if (overflow <= 0.5) {
          _setTicking(false);
          return text;
        }

        final clipped = SizedBox(height: viewport, child: text);
        if (!animate) {
          _setTicking(false);
          return ClipRect(child: clipped);
        }

        _setTicking(true);
        final scrollMs = overflow / _kHeroNameSpeed * 1000.0;
        final holdMs = _kHeroNameHold.inMilliseconds.toDouble();

        return ClipRect(
          child: ValueListenableBuilder<double>(
            valueListenable: _elapsedMs,
            child: clipped,
            builder: (context, elapsed, child) => Transform.translate(
              offset: Offset(
                0,
                -heroNameScrollOffset(
                  elapsedMs: elapsed,
                  overflow: overflow,
                  holdMs: holdMs,
                  scrollMs: scrollMs,
                ),
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class _HeroPlaceholder extends StatelessWidget {
  final String name;
  const _HeroPlaceholder({required this.name});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0x147996CE),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: const TextStyle(
            fontSize: 64,
            fontWeight: FontWeight.w700,
            color: _kText35,
          ),
        ),
      ),
    );
  }
}

// ─── Folded-in section header ────────────────────────────────────────────────

/// Header that separates a folded-in section (comments under the Info tab,
/// lorebooks under the Prompt Blocks tab) from the tab's primary content.
class _TabSectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  const _TabSectionHeader({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 15, color: context.cs.primary),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.77,
              color: context.cs.primary,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Info tab ──────────────────────────────────────────────────────────────

class _InfoTab extends StatelessWidget {
  final Character character;
  const _InfoTab({required this.character});

  @override
  Widget build(BuildContext context) {
    final tags = character.tags;
    final notes = character.creatorNotes;
    final hasNotes = notes != null && notes.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: tags.map((t) => _TagChip(tag: t)).toList(),
            ),
          ),
        if (hasNotes) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
            child: Text(
              'label_description'.tr().toUpperCase(),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.77,
                color: _kText35,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: _BioMarkdown(notes),
          ),
        ],
        if (tags.isEmpty && !hasNotes)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Text(
                'no_preview_available'.tr(),
                style: const TextStyle(color: _kText35),
              ),
            ),
          ),
      ],
    );
  }
}

/// Renders a character bio (JanitorAI `creatorNotes`, which is HTML) inside the
/// site's default markdown block. HTML is converted to markdown, then split into
/// alignment runs ([splitBioAlignment]) so each `<p style="text-align:…">` gets
/// its own `GptMarkdown` with the matching `textAlign` — unaligned text stays
/// left, exactly as before. gpt_markdown has no block-alignment of its own, so
/// this keeps alignment out of its parser (worst case: a run isn't centred).
class _BioMarkdown extends StatelessWidget {
  final String notes;
  const _BioMarkdown(this.notes);

  TextAlign? _mapAlign(String a) {
    switch (a) {
      case 'center':
        return TextAlign.center;
      case 'right':
        return TextAlign.right;
      case 'justify':
        return TextAlign.justify;
      default:
        return null;
    }
  }

  Widget _segment(BuildContext context, BioSegment seg) {
    return GptMarkdown(
      seg.text,
      textAlign: _mapAlign(seg.align),
      style: const TextStyle(fontSize: 13.5, height: 1.55, color: _kText75),
      onLinkTap: (url, title) async {
        final uri = Uri.tryParse(url);
        if (uri != null) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      imageBuilder: _bioImageBuilder,
      // A custom inlineComponents list replaces gpt_markdown's built-in inline
      // set, so emphasis parsers are listed explicitly. LinkedImageMd MUST come
      // before LinkMd (see its doc). Colours are left null so emphasis inherits
      // the bio text colour.
      inlineComponents: [
        HtmlColorMd(),
        GlowTextMd(),
        ColorGlowTextMd(),
        GradientTextMd(),
        BackgroundTextMd(),
        ColoredBoldMd(),
        ColoredUnderscoreBoldMd(),
        ColoredItalicMd(),
        ColoredUnderscoreItalicMd(),
        LinkedImageMd(),
        LinkMd(),
        ImageMd(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final md = hasHtmlTags(notes) ? htmlToMarkdown(notes) : notes;
    final segments = splitBioAlignment(md);
    return Container(
      // JanitorAI's default bio block (`.characterInfoMarkdownContent`):
      // translucent black panel, faint purple border, rounded, 1rem pad.
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x7B000000),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x1A8B5CF6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _segment(context, segments[i]),
          ],
        ],
      ),
    );
  }
}

/// Shared image renderer for bio markdown: network (`http`/`https`), `data:`
/// URIs, and local files. Used by every bio segment's `GptMarkdown`.
Widget _bioImageBuilder(
  BuildContext context,
  String url,
  double? width,
  double? height,
) {
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: url,
        width: width,
        height: height,
        fit: BoxFit.contain,
      ),
    );
  }
  if (url.startsWith('data:')) {
    final commaIdx = url.indexOf(',');
    if (commaIdx > 0) {
      try {
        final bytes = Uri.parse(url).data!.contentAsBytes();
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            bytes,
            width: width,
            height: height,
            fit: BoxFit.contain,
          ),
        );
      } catch (_) {}
    }
  }
  final file = File(url);
  if (file.existsSync()) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        file,
        width: width,
        height: height,
        fit: BoxFit.contain,
      ),
    );
  }
  return const SizedBox.shrink();
}

class _TagChip extends StatelessWidget {
  final String tag;
  const _TagChip({required this.tag});

  @override
  Widget build(BuildContext context) {
    final Color bg, fg, border;
    if (tag == 'NSFW') {
      bg = _kNsfwBg;
      fg = _kNsfw;
      border = _kNsfwBorder;
    } else if (tag == 'SFW') {
      bg = _kSfwBg;
      fg = _kSfw;
      border = _kSfwBorder;
    } else if (tag.startsWith('#')) {
      bg = const Color(0x1A00FFFF);
      fg = const Color(0xFF00CCCC);
      border = const Color(0x3300FFFF);
    } else {
      bg = _kAccentDim;
      fg = context.cs.primary;
      border = _kAccentBorder;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Text(
        tag,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

// ─── Prompts tab ───────────────────────────────────────────────────────────

class _PromptsTab extends StatefulWidget {
  final Character character;
  const _PromptsTab({required this.character});

  @override
  State<_PromptsTab> createState() => _PromptsTabState();
}

class _PromptsTabState extends State<_PromptsTab> {
  final Map<String, bool> _expanded = {};

  List<({String key, String label, String text})> get _sections {
    final c = widget.character;
    return [
      (
        key: 'description',
        label: 'label_description'.tr(),
        text: c.description ?? '',
      ),
      (
        key: 'personality',
        label: 'label_personality'.tr(),
        text: c.personality ?? '',
      ),
      (key: 'scenario', label: 'label_scenario'.tr(), text: c.scenario ?? ''),
      (
        key: 'mesExample',
        label: 'label_mes_example'.tr(),
        text: c.mesExample ?? '',
      ),
      (
        key: 'systemPrompt',
        label: 'role_system'.tr(),
        text: c.systemPrompt ?? '',
      ),
      (
        key: 'postHistory',
        label: 'role_system'.tr(),
        text: c.postHistoryInstructions ?? '',
      ),
    ].where((s) => s.text.isNotEmpty).toList();
  }

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    final firstMessages = characterFirstMessages(widget.character);

    return Column(
      children: [
        ...sections.map(
          (s) => _AccordionCard(
            key: ValueKey(s.key),
            label: s.label,
            text: s.text,
            expanded: _expanded[s.key] ?? false,
            onToggle: () =>
                setState(() => _expanded[s.key] = !(_expanded[s.key] ?? false)),
          ),
        ),
        if (firstMessages.isNotEmpty)
          _FirstMessagesCard(
            key: const ValueKey('firstMessages'),
            messages: firstMessages,
            expanded: _expanded['firstMessages'] ?? false,
            onToggle: () => setState(
              () => _expanded['firstMessages'] =
                  !(_expanded['firstMessages'] ?? false),
            ),
            isMessageExpanded: (n) => _expanded['firstMessage_$n'] ?? false,
            onToggleMessage: (n) => setState(
              () => _expanded['firstMessage_$n'] =
                  !(_expanded['firstMessage_$n'] ?? false),
            ),
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}

/// The opening lines a character carries, numbered the way the character
/// editor numbers them: slot 1 is `firstMes`, the alternate greetings follow.
/// Empty slots are dropped but do not renumber the ones after them, so the
/// message shown as "#3" in the sheet is the one the editor opens as "#3".
List<({int number, String text})> characterFirstMessages(Character c) {
  final all = [c.firstMes ?? '', ...c.alternateGreetings];
  return [
    for (var i = 0; i < all.length; i++)
      if (all[i].isNotEmpty) (number: i + 1, text: all[i]),
  ];
}

/// Every opening line in one card instead of one loose card per greeting, each
/// numbered `First message #N`. The old layout gave the character's own first
/// message a different label from the alternates that follow it, and labelled
/// those with the *placeholder* string, ellipsis and all ("Greeting... 2").
class _FirstMessagesCard extends StatelessWidget {
  final List<({int number, String text})> messages;
  final bool expanded;
  final VoidCallback onToggle;
  final bool Function(int number) isMessageExpanded;
  final ValueChanged<int> onToggleMessage;

  const _FirstMessagesCard({
    super.key,
    required this.messages,
    required this.expanded,
    required this.onToggle,
    required this.isMessageExpanded,
    required this.onToggleMessage,
  });

  @override
  Widget build(BuildContext context) {
    // A character with a single opening line has nothing to choose between, so
    // opening the card shows it rather than asking for a second tap.
    final single = messages.length == 1;
    return _AccordionShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AccordionHeader(
            label: 'label_first_messages'.tr(),
            expanded: expanded,
            onToggle: onToggle,
            badge: messages.length > 1 ? '${messages.length}' : null,
          ),
          AnimatedCrossFade(
            crossFadeState: expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 280),
            sizeCurve: Curves.easeOutCubic,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final m in messages)
                  _FirstMessageRow(
                    key: ValueKey(m.number),
                    number: m.number,
                    text: m.text,
                    expanded: single || isMessageExpanded(m.number),
                    onToggle: single ? null : () => onToggleMessage(m.number),
                  ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One opening line inside [_FirstMessagesCard]. Collapsible in its own right —
/// a character with a dozen greetings is a wall of text otherwise — unless it
/// is the only one, in which case [onToggle] is null and it stays open.
class _FirstMessageRow extends StatelessWidget {
  final int number;
  final String text;
  final bool expanded;
  final VoidCallback? onToggle;

  const _FirstMessageRow({
    super.key,
    required this.number,
    required this.text,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, thickness: 1, color: _kBorderLine),
        GestureDetector(
          onTap: onToggle,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'label_first_message_n'.tr(args: ['$number']),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                      color: _kText50,
                    ),
                  ),
                ),
                if (onToggle != null)
                  AnimatedRotation(
                    turns: expanded ? 0.0 : 0.5,
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    child: const Icon(
                      Icons.keyboard_arrow_up_rounded,
                      color: _kText35,
                      size: 20,
                    ),
                  ),
              ],
            ),
          ),
        ),
        _CollapsibleText(text: text, expanded: expanded),
      ],
    );
  }
}

class _AccordionCard extends StatelessWidget {
  final String label;
  final String text;
  final bool expanded;
  final VoidCallback onToggle;

  const _AccordionCard({
    super.key,
    required this.label,
    required this.text,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return _AccordionShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AccordionHeader(
            label: label,
            expanded: expanded,
            onToggle: onToggle,
          ),
          _CollapsibleText(text: text, expanded: expanded),
        ],
      ),
    );
  }
}

/// The card the prompt accordions are drawn on.
class _AccordionShell extends StatelessWidget {
  final Widget child;

  const _AccordionShell({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kBorderLine),
      ),
      child: child,
    );
  }
}

/// Title row of a prompt accordion: the label, an optional count, and the
/// chevron that turns as the card opens.
class _AccordionHeader extends StatelessWidget {
  final String label;
  final bool expanded;
  final VoidCallback onToggle;
  final String? badge;

  const _AccordionHeader({
    required this.label,
    required this.expanded,
    required this.onToggle,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.65,
                  color: context.cs.primary,
                ),
              ),
            ),
            if (badge != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: _kAccentDim,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _kAccentBorder),
                ),
                child: Text(
                  badge!,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: context.cs.primary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            AnimatedRotation(
              turns: expanded ? 0.0 : 0.5,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              child: const Icon(
                Icons.keyboard_arrow_up_rounded,
                color: _kText50,
                size: 24,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Body of a prompt accordion: a faded three-line taste when closed, the whole
/// selectable text when open.
class _CollapsibleText extends StatelessWidget {
  final String text;
  final bool expanded;

  const _CollapsibleText({required this.text, required this.expanded});

  @override
  Widget build(BuildContext context) {
    return AnimatedCrossFade(
      crossFadeState: expanded
          ? CrossFadeState.showSecond
          : CrossFadeState.showFirst,
      duration: const Duration(milliseconds: 280),
      sizeCurve: Curves.easeOutCubic,
      firstChild: ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0.45, 1.0],
          colors: [Colors.white, Colors.transparent],
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.clip,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.55,
              color: _kText75,
            ),
          ),
        ),
      ),
      secondChild: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: SelectableText(
          text,
          style: const TextStyle(
            fontSize: 13.5,
            height: 1.55,
            color: _kText75,
          ),
        ),
      ),
    );
  }
}
