import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop_popup.dart';
import '../shell/desktop/desktop_layout_provider.dart';
import '../../core/platform/haptics.dart';
import '../theme/app_colors.dart';
import '../../features/settings/app_settings_provider.dart';
import 'glass_surface.dart';
import 'top_edge_blur.dart';

// ── Data models ───────────────────────────────────────────────────────────────

class BottomSheetAction {
  final IconData icon;
  final Color? color;
  final VoidCallback onTap;

  const BottomSheetAction({
    required this.icon,
    this.color,
    required this.onTap,
  });
}

class BottomSheetItem {
  final String label;
  final IconData? icon;
  final Color? iconColor;
  final VoidCallback onTap;
  final bool isDestructive;
  final String? hint;
  final bool centered;
  final List<BottomSheetAction> actions;

  const BottomSheetItem({
    required this.label,
    this.icon,
    this.iconColor,
    required this.onTap,
    this.isDestructive = false,
    this.hint,
    this.centered = false,
    this.actions = const [],
  });
}

class BottomSheetSessionItem {
  final String title;
  final int count;
  final String time;
  final String preview;
  final bool isActive;

  /// Session has a reply the user has not seen. Renders the same leading dot
  /// and bolder title the chat list uses.
  final bool unread;

  /// A reply is streaming into this session right now. Replaces [preview] with
  /// the chat list's "typing" line.
  final bool generating;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const BottomSheetSessionItem({
    required this.title,
    required this.count,
    required this.time,
    required this.preview,
    this.isActive = false,
    this.unread = false,
    this.generating = false,
    required this.onTap,
    required this.onMore,
  });
}

class BottomSheetCardItem {
  final String label;
  final String? sublabel;
  final IconData? icon;
  final String? faviconUrl;
  final String? imageUrl;
  final String? badge;
  final bool isFeatured;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final List<BottomSheetAction> actions;

  /// Stable identity of the row, used as its key while the list is
  /// drag-ordered — labels can repeat, and a row must keep its widget (and its
  /// press state) as it moves. Required by [BottomSheetCards.onReorder], and
  /// ignored otherwise.
  final String? id;

  const BottomSheetCardItem({
    required this.label,
    this.sublabel,
    this.icon,
    this.faviconUrl,
    this.imageUrl,
    this.badge,
    this.isFeatured = false,
    this.isActive = false,
    required this.onTap,
    this.onLongPress,
    this.actions = const [],
    this.id,
  });
}

/// The card list of a sheet built from live state — see [BottomSheetCards].
typedef BottomSheetCardsBuilder =
    BottomSheetCards Function(BuildContext context, WidgetRef ref);

/// A card list rebuilt on every sheet rebuild, so the sheet can follow state
/// that changes while it is open (rows added, reordered, renamed) instead of
/// showing the snapshot it was opened with.
///
/// The builder runs inside the sheet's own `ConsumerState`, so anything it
/// watches on [WidgetRef] rebuilds the list in place.
class BottomSheetCards {
  final List<BottomSheetCardItem> items;

  /// Non-null turns the list into a drag-ordered one: a long press lifts a row
  /// and the callback reports where it landed. Indices are final positions —
  /// the lift out of `oldIndex` is already accounted for.
  ///
  /// Rows are not filtered while dragging is on: a search mask and drag indices
  /// describe different lists, so a reorderable sheet is never searchable.
  final ReorderCallback? onReorder;

  BottomSheetCards({required this.items, this.onReorder})
    : assert(
        onReorder == null || items.every((i) => i.id != null),
        'Drag-ordered card rows need an id to key them by.',
      );
}

class BottomSheetBigInfo {
  final IconData icon;
  final String description;
  final String? buttonText;
  final bool buttonDisabled;
  final VoidCallback? onButtonTap;

  const BottomSheetBigInfo({
    required this.icon,
    required this.description,
    this.buttonText,
    this.buttonDisabled = false,
    this.onButtonTap,
  });
}

class BottomSheetInput {
  final String placeholder;
  final String value;
  final String confirmLabel;
  final void Function(String) onConfirm;

  const BottomSheetInput({
    required this.placeholder,
    this.value = '',
    this.confirmLabel = 'Save',
    required this.onConfirm,
  });
}

typedef BottomSheetItemBuilder =
    BottomSheetItem Function(BuildContext context, int index);

/// Per-row collapse/expand used while a search query filters a sheet list.
/// Long enough to read as a transition, short enough not to lag typing.
const Duration _kFilterAnimDuration = Duration(milliseconds: 220);

// ── Public API ────────────────────────────────────────────────────────────────

class GlazeBottomSheet {
  static Future<T?> show<T>(
    BuildContext context, {
    String? title,
    Widget? headerAction,
    List<BottomSheetItem>? items,
    int? itemCount,
    BottomSheetItemBuilder? itemBuilder,
    List<BottomSheetItem>? itemsAsCards,
    List<BottomSheetSessionItem>? sessionItems,
    List<BottomSheetCardItem>? cardItems,
    BottomSheetCardsBuilder? cardsBuilder,
    BottomSheetBigInfo? bigInfo,
    BottomSheetInput? input,
    Widget? child,
    bool locked = false,
    bool isDismissible = true,
    int? scrollToIndex,
    bool searchable = false,
    String? searchHint,
    bool autofocusSearch = false,
  }) {
    assert(
      (itemCount == null) == (itemBuilder == null),
      'itemCount and itemBuilder must be provided together.',
    );
    assert(
      itemBuilder == null || items == null,
      'items and itemBuilder cannot be used together.',
    );
    assert(
      itemCount == null || itemCount >= 0,
      'itemCount cannot be negative.',
    );
    assert(
      itemBuilder == null ||
          (itemsAsCards == null &&
              sessionItems == null &&
              cardItems == null &&
              bigInfo == null &&
              input == null &&
              child == null),
      'Lazy items cannot be combined with other sheet body content.',
    );
    assert(
      itemBuilder == null || scrollToIndex == null,
      'scrollToIndex is only supported for materialized items.',
    );
    assert(
      cardsBuilder == null || (cardItems == null && itemBuilder == null),
      'cardsBuilder replaces cardItems — pass one or the other.',
    );
    assert(
      !searchable || itemBuilder == null,
      'Search filters materialized lists only — a lazy builder has no labels '
      'to match against.',
    );
    // Desktop: a plain list of actions is a menu, not a sheet. Vue routed
    // exactly this shape through `DesktopPopup`; anything richer (cards,
    // sessions, an input, a custom child, search) still gets the real sheet.
    final isPlainMenu =
        items != null &&
        items.isNotEmpty &&
        itemBuilder == null &&
        itemsAsCards == null &&
        sessionItems == null &&
        cardItems == null &&
        cardsBuilder == null &&
        bigInfo == null &&
        input == null &&
        child == null &&
        headerAction == null &&
        !searchable;
    if (isPlainMenu && isDesktopLayout(context)) {
      return showDesktopPopup<T>(
        context,
        title: title,
        entries: [
          for (final item in items)
            DesktopPopupEntry(
              label: item.label,
              icon: item.icon,
              iconColor: item.iconColor,
              hint: item.hint,
              isDestructive: item.isDestructive,
              onTap: item.onTap,
              actions: [
                for (final action in item.actions)
                  DesktopPopupAction(
                    icon: action.icon,
                    color: action.color,
                    onTap: action.onTap,
                  ),
              ],
            ),
        ],
      );
    }

    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      enableDrag: !locked,
      isDismissible: isDismissible,
      isScrollControlled: true,
      builder: (_) => _GlazeBottomSheetContent(
        title: title,
        headerAction: headerAction,
        items: items,
        itemCount: itemCount,
        itemBuilder: itemBuilder,
        itemsAsCards: itemsAsCards,
        sessionItems: sessionItems,
        cardItems: cardItems,
        cardsBuilder: cardsBuilder,
        bigInfo: bigInfo,
        input: input,
        locked: locked,
        scrollToIndex: scrollToIndex,
        searchable: searchable,
        searchHint: searchHint,
        autofocusSearch: autofocusSearch,
        child: child,
      ),
    );
  }
}

// ── Sheet content ─────────────────────────────────────────────────────────────

class GlazeBottomSheetFrame extends ConsumerWidget {
  final Widget child;
  final bool showHandle;
  final double maxHeightFactor;

  /// Explicit pixel cap on the sheet height. When set it overrides
  /// [maxHeightFactor] — used when the sheet must fit a constrained slot (e.g.
  /// the color picker, which must not cover the pinned preview above it).
  final double? maxHeight;

  const GlazeBottomSheetFrame({
    super.key,
    required this.child,
    this.showHandle = true,
    this.maxHeightFactor = 0.95,
    this.maxHeight,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cap =
        maxHeight ?? MediaQuery.of(context).size.height * maxHeightFactor;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: cap),
      child: GlassSurface(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: context.cs.outlineVariant)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHandle) _HandleBar(),
            Flexible(fit: FlexFit.loose, child: child),
          ],
        ),
      ),
    );
  }
}

class _GlazeBottomSheetContent extends ConsumerStatefulWidget {
  final String? title;
  final Widget? headerAction;
  final List<BottomSheetItem>? items;
  final int? itemCount;
  final BottomSheetItemBuilder? itemBuilder;
  final List<BottomSheetItem>? itemsAsCards;
  final List<BottomSheetSessionItem>? sessionItems;
  final List<BottomSheetCardItem>? cardItems;
  final BottomSheetCardsBuilder? cardsBuilder;
  final BottomSheetBigInfo? bigInfo;
  final BottomSheetInput? input;
  final Widget? child;
  final bool locked;
  final int? scrollToIndex;
  final bool searchable;
  final String? searchHint;
  final bool autofocusSearch;

  const _GlazeBottomSheetContent({
    this.title,
    this.headerAction,
    this.items,
    this.itemCount,
    this.itemBuilder,
    this.itemsAsCards,
    this.sessionItems,
    this.cardItems,
    this.cardsBuilder,
    this.bigInfo,
    this.input,
    this.child,
    required this.locked,
    this.scrollToIndex,
    this.searchable = false,
    this.searchHint,
    this.autofocusSearch = false,
  });

  @override
  ConsumerState<_GlazeBottomSheetContent> createState() =>
      _GlazeBottomSheetContentState();
}

class _GlazeBottomSheetContentState
    extends ConsumerState<_GlazeBottomSheetContent> {
  late final TextEditingController _inputController;
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final _headerKey = GlobalKey();
  final _scrollTargetKey = GlobalKey();
  final _bodyKey = GlobalKey();
  double _headerH = 52; // Estimate initial height

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// Lower-cased whitespace-separated tokens of the search query. Empty means
  /// "no filter", which short-circuits every visibility computation below.
  List<String> _queryTokens = const [];

  /// Height the unfiltered body settled at, capped to the viewport. Applied as
  /// a floor while filtering so the sheet keeps its size (and the search field
  /// keeps its place) instead of collapsing under the shrinking result list.
  double? _stableBodyH;

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController(text: widget.input?.value ?? '');
    if (widget.input != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FocusScope.of(context).requestFocus(_inputFocus);
      });
    }
    if (widget.scrollToIndex != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _scrollTargetKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.5,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _measureHeader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final h = box.size.height;
      if (h != _headerH) {
        setState(() => _headerH = h);
      }
    });
  }

  /// Records the body's natural height once, on the first frame (query still
  /// empty), so [_stableBodyH] can pin the sheet while results are filtered
  /// out. Registered after [_measureHeader] so the cap uses the measured
  /// header height, not the initial estimate.
  void _measureBody(double safeBottom) {
    if (!widget.searchable || _stableBodyH != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _stableBodyH != null) return;
      final box = _bodyKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final cap =
          MediaQuery.of(context).size.height * 0.95 -
          _headerH -
          safeBottom -
          20;
      if (cap <= 0) return;
      final h = box.size.height.clamp(0.0, cap);
      if (h > 0) setState(() => _stableBodyH = h);
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocus.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool get _hasHeader => widget.title != null || widget.headerAction != null;

  void _onSearchChanged(String value) {
    setState(() {
      _queryTokens = value
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList(growable: false);
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _queryTokens = const []);
  }

  /// Per-entry visibility for one of the sheet's lists, or null when nothing is
  /// being filtered (the common case — callers then skip the reveal wrappers
  /// entirely).
  List<bool>? _visibility<T>(
    List<T>? entries,
    List<String?> Function(T) fields,
  ) {
    if (entries == null || _queryTokens.isEmpty) return null;
    return entries
        .map((e) => _matchesQuery(_queryTokens, fields(e)))
        .toList(growable: false);
  }

  Widget _buildLazyList(BuildContext context, EdgeInsets padding) {
    return CustomScrollView(
      controller: _scrollController,
      shrinkWrap: true,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16).add(padding),
          sliver: SliverList.builder(
            itemCount: widget.itemCount,
            itemBuilder: (context, index) => _LazyItemRow(
              item: widget.itemBuilder!(context, index),
              isFirst: index == 0,
              isLast: index == widget.itemCount! - 1,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    // The modal route wraps us in SafeArea(bottom: false), so the sheet must
    // reserve the system navigation-bar inset itself — otherwise (in
    // edge-to-edge) the last row sits under the nav bar. padding.bottom is 0
    // while the keyboard is up, so it never double-counts with bottomInset.
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final batterySaver = ref.watch(
      appSettingsProvider.select((s) => s.value?.batterySaver ?? false),
    );

    _measureHeader();
    _measureBody(safeBottom);

    // Battery saver drops the reveal animation: filtered rows are simply not
    // built, so typing costs a plain rebuild with no per-row controllers.
    final animateFilter = widget.searchable && !batterySaver;
    // Built inside this build, so whatever the builder watches on `ref` keeps
    // the rows in step with the state behind them while the sheet is open.
    final cards = widget.cardsBuilder?.call(context, ref);
    final cardItems = cards?.items ?? widget.cardItems;
    final itemsVisible = _visibility(widget.items, (i) => [i.label, i.hint]);
    final cardsVisible = _visibility(
      widget.itemsAsCards,
      (i) => [i.label, i.hint],
    );
    final sessionsVisible = _visibility(
      widget.sessionItems,
      (i) => [i.title, i.preview],
    );
    final cardItemsVisible = _visibility(
      cardItems,
      (i) => [i.label, i.sublabel, i.badge],
    );
    final noResults =
        _queryTokens.isNotEmpty &&
        !_hasMatch(itemsVisible) &&
        !_hasMatch(cardsVisible) &&
        !_hasMatch(sessionsVisible) &&
        !_hasMatch(cardItemsVisible);

    final sheetBody = ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.95,
      ),
      child: GlassSurface(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: context.cs.outlineVariant)),
        child: Stack(
          children: [
            TopEdgeBlur(
              enabled: !batterySaver,
              height: _headerH + 8,
              sigma: 24,
              tintColor: context.cs.surface.withValues(alpha: 0.88),
              child: Padding(
                // Only the header is reserved as an *outer* inset. The
                // nav-bar/keyboard inset goes *inside* the scroll view as
                // content padding (below), so the viewport still reaches the
                // sheet's bottom edge: list rows stay visible scrolling behind
                // the nav bar, while the last row (e.g. Cancel/Save) rests
                // above it. Reserving it out here instead would shrink the
                // viewport and leave a dead strip no content can scroll into.
                padding: EdgeInsets.only(top: _headerH),
                child: RawScrollbar(
                  controller: _scrollController,
                  thumbColor: Colors.white.withValues(alpha: 0.15),
                  radius: const Radius.circular(3),
                  thickness: 4,
                  padding: const EdgeInsets.only(right: 3),
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    child: widget.itemBuilder != null
                        ? _buildLazyList(
                            context,
                            EdgeInsets.only(
                              bottom: bottomInset + safeBottom + 16,
                            ),
                          )
                        : SingleChildScrollView(
                            controller: _scrollController,
                            padding: EdgeInsets.only(
                              bottom: bottomInset + safeBottom + 16,
                            ),
                            // Isolates the sheet content in its own layer so a
                            // scroll only shifts the layer instead of re-recording
                            // every row each frame.
                            child: RepaintBoundary(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: _stableBodyH ?? 0,
                                ),
                                child: Column(
                                  key: _bodyKey,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(height: 4),
                                    if (widget.child != null) widget.child!,
                                    if (widget.bigInfo != null)
                                      _BigInfo(info: widget.bigInfo!),
                                    if (widget.items != null &&
                                        widget.items!.isNotEmpty)
                                      _ItemsList(
                                        items: widget.items!,
                                        visible: itemsVisible,
                                        animateFilter: animateFilter,
                                        scrollToIndex: widget.scrollToIndex,
                                        scrollTargetKey: _scrollTargetKey,
                                      ),
                                    if (widget.itemsAsCards != null &&
                                        widget.itemsAsCards!.isNotEmpty)
                                      _ItemsCardList(
                                        items: widget.itemsAsCards!,
                                        visible: cardsVisible,
                                        animateFilter: animateFilter,
                                      ),
                                    if (widget.sessionItems != null &&
                                        widget.sessionItems!.isNotEmpty)
                                      GlazeSessionList(
                                        items: widget.sessionItems!,
                                        visible: sessionsVisible,
                                        animateFilter: animateFilter,
                                      ),
                                    if (cardItems != null &&
                                        cardItems.isNotEmpty)
                                      _CardList(
                                        items: cardItems,
                                        visible: cardItemsVisible,
                                        animateFilter: animateFilter,
                                        onReorder: cards?.onReorder,
                                      ),
                                    if (widget.searchable)
                                      _SheetReveal(
                                        visible: noResults,
                                        animate: animateFilter,
                                        child: const _SearchEmptyState(),
                                      ),
                                    if (widget.input != null)
                                      _InputSection(
                                        input: widget.input!,
                                        controller: _inputController,
                                        focusNode: _inputFocus,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ),

            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: KeyedSubtree(
                key: _headerKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _HandleBar(),
                    if (_hasHeader)
                      _Header(title: widget.title, action: widget.headerAction),
                    if (widget.searchable)
                      _SheetSearchField(
                        controller: _searchController,
                        focusNode: _searchFocus,
                        hint: widget.searchHint,
                        autofocus: widget.autofocusSearch,
                        hasQuery: _searchController.text.isNotEmpty,
                        onChanged: _onSearchChanged,
                        onClear: _clearSearch,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return sheetBody;
  }
}

// ── Search & filter animation ─────────────────────────────────────────────────

/// True when every token of the query appears somewhere in [fields]. Tokens
/// are matched independently, so "gpt 4o" finds `gpt-4o-mini` and the caller's
/// field order doesn't matter.
bool _matchesQuery(List<String> tokens, List<String?> fields) {
  if (tokens.isEmpty) return true;
  final buf = StringBuffer();
  for (final f in fields) {
    if (f == null || f.isEmpty) continue;
    buf
      ..write(f.toLowerCase())
      ..write(' ');
  }
  final hay = buf.toString();
  for (final token in tokens) {
    if (!hay.contains(token)) return false;
  }
  return true;
}

/// Whether a list should render at all: a null mask means "not filtered", so
/// everything the list holds is visible.
bool _anyVisible(List<bool>? visible) =>
    visible == null || visible.contains(true);

/// Whether a *filtered* list kept at least one row. Unlike [_anyVisible], a
/// null mask counts as "no matches" — it means the sheet simply has no list of
/// that kind, which must not suppress the empty state.
bool _hasMatch(List<bool>? visible) =>
    visible != null && visible.contains(true);

/// Collapse/expand transition for a single row of a filtered sheet list.
///
/// Rows stay mounted and animate their own height, opacity and a small
/// horizontal slide, so a filtered-out row folds away instead of popping and
/// the sheet's height follows along smoothly. With [animate] false (battery
/// saver, or a sheet with no search field) the row is built or dropped outright
/// — no controllers, no clip layers, no per-frame cost.
class _SheetReveal extends StatelessWidget {
  final bool visible;
  final bool animate;
  final Widget child;

  const _SheetReveal({
    required this.visible,
    required this.animate,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!animate) {
      return visible ? child : const SizedBox.shrink();
    }
    return TweenAnimationBuilder<double>(
      // begin only seeds the very first build; afterwards the implicit
      // animation runs from the row's current value to the new end.
      tween: Tween<double>(
        begin: visible ? 1.0 : 0.0,
        end: visible ? 1.0 : 0.0,
      ),
      duration: _kFilterAnimDuration,
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, t, child) {
        if (t >= 1) return child!;
        if (t <= 0) return const SizedBox.shrink();
        final f = t.clamp(0.0, 1.0);
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: f,
            child: Opacity(
              opacity: f,
              child: Transform.translate(
                offset: Offset(16 * (1 - f), 0),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SheetSearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? hint;
  final bool autofocus;
  final bool hasQuery;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SheetSearchField({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.autofocus,
    required this.hasQuery,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        cursorColor: context.cs.primary,
        style: TextStyle(color: context.cs.onSurface, fontSize: 14),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint ?? 'search'.tr(),
          hintStyle: TextStyle(
            color: context.cs.onSurfaceVariant,
            fontSize: 14,
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 18,
            color: context.cs.onSurfaceVariant,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 38,
            minHeight: 0,
          ),
          // Always mounted, only faded: the sheet body reserves the header
          // height as a static top inset, so a suffix that comes and goes
          // would resize the header out from under the list.
          suffixIcon: AnimatedOpacity(
            opacity: hasQuery ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 120),
            child: IgnorePointer(
              ignoring: !hasQuery,
              child: GestureDetector(
                onTap: onClear,
                behavior: HitTestBehavior.opaque,
                child: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 38,
            minHeight: 0,
          ),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.06),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: context.cs.primary.withValues(alpha: 0.5),
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 11),
        ),
      ),
    );
  }
}

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 36,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          Text(
            'no_results'.tr(),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _HandleBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          width: 32,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String? title;
  final Widget? action;

  const _Header({this.title, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title ?? '',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: context.cs.onSurface,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _ItemsList extends StatelessWidget {
  final List<BottomSheetItem> items;

  /// Per-item search visibility, or null when the list is unfiltered.
  final List<bool>? visible;
  final bool animateFilter;
  final int? scrollToIndex;
  final Key? scrollTargetKey;

  const _ItemsList({
    required this.items,
    this.visible,
    this.animateFilter = false,
    this.scrollToIndex,
    this.scrollTargetKey,
  });

  bool _isVisible(int i) => visible == null || visible![i];

  @override
  Widget build(BuildContext context) {
    // The separator rides *above* its row, so the topmost surviving row must
    // drop it — otherwise a filtered list opens with a stray hairline.
    var firstVisible = -1;
    for (var i = 0; i < items.length; i++) {
      if (_isVisible(i)) {
        firstVisible = i;
        break;
      }
    }
    return _SheetReveal(
      visible: firstVisible >= 0,
      animate: animateFilter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (int i = 0; i < items.length; i++)
                _SheetReveal(
                  visible: _isVisible(i),
                  animate: animateFilter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (i != firstVisible)
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: Colors.white.withValues(alpha: 0.06),
                        ),
                      KeyedSubtree(
                        key: i == scrollToIndex ? scrollTargetKey : null,
                        child: _ItemRow(item: items[i]),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemRow extends StatefulWidget {
  final BottomSheetItem item;

  const _ItemRow({required this.item});

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        setState(() => _pressed = false);
        Haptics.selectionClick();
        item.onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        color: _pressed
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            if (item.icon != null) ...[
              Icon(
                item.icon,
                size: 22,
                color:
                    item.iconColor ??
                    (item.isDestructive
                        ? const Color(0xFFFF4444)
                        : context.cs.onSurfaceVariant),
              ),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: item.centered
                  ? Center(child: _ItemLabel(item: item))
                  : _ItemLabel(item: item),
            ),
            if (item.actions.isNotEmpty)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: item.actions
                    .map(
                      (a) => GestureDetector(
                        onTap: a.onTap,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            a.icon,
                            size: 22,
                            color: a.color ?? context.cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }
}

class _LazyItemRow extends StatelessWidget {
  final BottomSheetItem item;
  final bool isFirst;
  final bool isLast;

  const _LazyItemRow({
    required this.item,
    required this.isFirst,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.vertical(
        top: isFirst ? const Radius.circular(16) : Radius.zero,
        bottom: isLast ? const Radius.circular(16) : Radius.zero,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          border: Border(
            top: BorderSide(
              color: Colors.white.withValues(alpha: isFirst ? 0.1 : 0.06),
            ),
            left: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            right: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            bottom: isLast
                ? BorderSide(color: Colors.white.withValues(alpha: 0.1))
                : BorderSide.none,
          ),
        ),
        child: _ItemRow(item: item),
      ),
    );
  }
}

class _ItemsCardList extends StatelessWidget {
  final List<BottomSheetItem> items;
  final List<bool>? visible;
  final bool animateFilter;

  const _ItemsCardList({
    required this.items,
    this.visible,
    this.animateFilter = false,
  });

  @override
  Widget build(BuildContext context) {
    return _SheetReveal(
      visible: _anyVisible(visible),
      animate: animateFilter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          children: [
            for (int i = 0; i < items.length; i++)
              _SheetReveal(
                visible: visible == null || visible![i],
                animate: animateFilter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ItemCardRow(item: items[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ItemCardRow extends StatefulWidget {
  final BottomSheetItem item;

  const _ItemCardRow({required this.item});

  @override
  State<_ItemCardRow> createState() => _ItemCardRowState();
}

class _ItemCardRowState extends State<_ItemCardRow> {
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () {
          Haptics.selectionClick();
          item.onTap();
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(
                  item.icon,
                  size: 22,
                  color:
                      item.iconColor ??
                      (item.isDestructive
                          ? const Color(0xFFFF4444)
                          : context.cs.onSurfaceVariant),
                ),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: item.centered
                    ? Center(child: _ItemLabel(item: item))
                    : _ItemLabel(item: item),
              ),
              if (item.actions.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: item.actions
                      .map(
                        (a) => GestureDetector(
                          onTap: a.onTap,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Icon(
                              a.icon,
                              size: 22,
                              color: a.color ?? context.cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemLabel extends StatelessWidget {
  final BottomSheetItem item;

  const _ItemLabel({required this.item});

  @override
  Widget build(BuildContext context) {
    final color = item.isDestructive
        ? const Color(0xFFFF4444)
        : context.cs.onSurface;
    if (item.hint != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.label, style: TextStyle(fontSize: 16, color: color)),
          const SizedBox(height: 2),
          Text(
            item.hint!,
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
        ],
      );
    }
    return Text(item.label, style: TextStyle(fontSize: 16, color: color));
  }
}

class GlazeSessionList extends StatelessWidget {
  final List<BottomSheetSessionItem> items;

  /// Per-item search visibility, or null when the list is unfiltered.
  final List<bool>? visible;
  final bool animateFilter;

  const GlazeSessionList({
    super.key,
    required this.items,
    this.visible,
    this.animateFilter = false,
  });

  @override
  Widget build(BuildContext context) {
    return _SheetReveal(
      visible: _anyVisible(visible),
      animate: animateFilter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          children: [
            for (int i = 0; i < items.length; i++)
              _SheetReveal(
                visible: visible == null || visible![i],
                animate: animateFilter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: GlazeSessionRow(item: items[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class GlazeSessionRow extends StatelessWidget {
  final BottomSheetSessionItem item;

  const GlazeSessionRow({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (item.unread) ...[
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: context.cs.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            item.title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: item.unread
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              color: context.cs.onSurface,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.chat_bubble_outline,
                              size: 13,
                              color: context.cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '${item.count}',
                              style: TextStyle(
                                fontSize: 12,
                                color: context.cs.onSurfaceVariant,
                              ),
                            ),
                            if (item.time.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Text(
                                  '·',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: context.cs.onSurfaceVariant
                                        .withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                              Text(
                                item.time,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    if (item.generating)
                      Row(
                        children: [
                          Icon(
                            Icons.edit,
                            size: 13,
                            color: context.cs.onSurfaceVariant.withValues(
                              alpha: 0.7,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'model_typing'.tr(),
                            style: TextStyle(
                              fontSize: 13,
                              fontStyle: FontStyle.italic,
                              color: context.cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      )
                    else
                      Text(
                        item.preview,
                        style: TextStyle(
                          fontSize: 13,
                          color: item.unread
                              ? context.cs.onSurface
                              : context.cs.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (item.isActive) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: context.cs.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  GestureDetector(
                    onTap: item.onMore,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.more_vert,
                        size: 20,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardList extends StatelessWidget {
  final List<BottomSheetCardItem> items;
  final List<bool>? visible;
  final bool animateFilter;

  /// Set by [BottomSheetCards.onReorder] — see there.
  final ReorderCallback? onReorder;

  const _CardList({
    required this.items,
    this.visible,
    this.animateFilter = false,
    this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    return _SheetReveal(
      visible: _anyVisible(visible),
      animate: animateFilter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: onReorder != null
            ? _buildReorderable()
            : Column(
                children: [
                  for (int i = 0; i < items.length; i++)
                    _SheetReveal(
                      visible: visible == null || visible![i],
                      animate: animateFilter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _CardRow(item: items[i]),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  /// The drag-ordered list. It sits inside the sheet's own scroll view, so it
  /// shrink-wraps its rows and leaves the scrolling to the sheet; a row is
  /// lifted by a long press, the same gesture the Presets list uses.
  ///
  /// Rows are built unfiltered here — a reorderable sheet is never searchable
  /// (see [BottomSheetCards.onReorder]).
  Widget _buildReorderable() {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      buildDefaultDragHandles: false,
      itemCount: items.length,
      onReorderItem: onReorder!,
      itemBuilder: (_, i) => ReorderableDelayedDragStartListener(
        key: ValueKey(items[i].id!),
        index: i,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _CardRow(item: items[i]),
        ),
      ),
    );
  }
}

class _CardRow extends StatefulWidget {
  final BottomSheetCardItem item;

  const _CardRow({required this.item});

  @override
  State<_CardRow> createState() => _CardRowState();
}

class _CardRowState extends State<_CardRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final hasImage = item.imageUrl != null;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        item.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      onLongPress: item.onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        constraints: hasImage ? const BoxConstraints(minHeight: 160) : null,
        decoration: BoxDecoration(
          color: _pressed
              ? context.cs.primary.withValues(alpha: 0.1)
              : item.isActive
              ? context.cs.primary.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.04),
          border: Border.all(
            color: item.isActive
                ? context.cs.primary.withValues(alpha: 0.4)
                : const Color(0xFF555555),
          ),
          borderRadius: BorderRadius.circular(12),
          image: hasImage
              ? DecorationImage(
                  image: NetworkImage(item.imageUrl!),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            if (hasImage)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.3),
                        Colors.black.withValues(alpha: 0.8),
                      ],
                    ),
                  ),
                ),
              ),
            if (item.isFeatured)
              Positioned(
                top: 10,
                left: 12,
                child: Text(
                  'label_featured_preset'.tr(),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.08 * 9,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if ((item.icon != null || item.faviconUrl != null) &&
                      !hasImage) ...[
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: context.cs.primary.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: item.faviconUrl != null
                          ? Image.network(
                              item.faviconUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  Icon(
                                    item.icon ?? Icons.api_rounded,
                                    size: 20,
                                    color: context.cs.primary,
                                  ),
                            )
                          : Icon(
                              item.icon,
                              size: 20,
                              color: context.cs.primary,
                            ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: _CardItemInfo(item: item, hasImage: hasImage),
                  ),
                  if (item.actions.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    _CardActions(actions: item.actions, hasImage: hasImage),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardItemInfo extends StatelessWidget {
  final BottomSheetCardItem item;
  final bool hasImage;

  const _CardItemInfo({required this.item, required this.hasImage});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                item.label,
                style: TextStyle(
                  fontSize: hasImage ? 16 : 15,
                  fontWeight: FontWeight.w600,
                  color: hasImage ? Colors.white : context.cs.onSurface,
                  shadows: hasImage
                      ? [const Shadow(color: Colors.black87, blurRadius: 3)]
                      : null,
                ),
              ),
            ),
            if (item.badge != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: hasImage
                      ? Colors.white.withValues(alpha: 0.2)
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: hasImage
                      ? Border.all(color: Colors.white.withValues(alpha: 0.1))
                      : null,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.description_outlined,
                      size: 12,
                      color: hasImage
                          ? Colors.white
                          : context.cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      item.badge!,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: hasImage
                            ? Colors.white
                            : context.cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        if (item.sublabel != null) ...[
          const SizedBox(height: 2),
          Text(
            item.sublabel!,
            style: TextStyle(
              fontSize: 12,
              color: hasImage ? Colors.white70 : context.cs.onSurfaceVariant,
              shadows: hasImage
                  ? [const Shadow(color: Colors.black87, blurRadius: 2)]
                  : null,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

class _CardActions extends StatelessWidget {
  final List<BottomSheetAction> actions;
  final bool hasImage;

  const _CardActions({required this.actions, required this.hasImage});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: actions
          .map(
            (a) => GestureDetector(
              onTap: a.onTap,
              child: Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.all(6),
                decoration: hasImage
                    ? BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        shape: BoxShape.circle,
                      )
                    : null,
                child: Icon(
                  a.icon,
                  size: 20,
                  color: hasImage
                      ? Colors.white
                      : (a.color ?? context.cs.onSurfaceVariant),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _BigInfo extends StatelessWidget {
  final BottomSheetBigInfo info;

  const _BigInfo({required this.info});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        children: [
          Icon(
            info.icon,
            size: 64,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            info.description,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: context.cs.onSurface,
              height: 1.5,
            ),
          ),
          if (info.buttonText != null) ...[
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: info.buttonDisabled ? null : info.onButtonTap,
                child: Text(info.buttonText!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InputSection extends StatelessWidget {
  final BottomSheetInput input;
  final TextEditingController controller;
  final FocusNode focusNode;

  const _InputSection({
    required this.input,
    required this.controller,
    required this.focusNode,
  });

  void _confirm(BuildContext context) {
    final value = controller.text.trim();
    if (value.isNotEmpty) {
      // Callers of BottomSheetInput.onConfirm are responsible for popping
      // the sheet themselves (so they can do it before/after their work as
      // needed). Don't pop here or we'd double-pop and unwind a real route.
      input.onConfirm(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        children: [
          TextField(
            controller: controller,
            focusNode: focusNode,
            style: TextStyle(color: context.cs.onSurface),
            decoration: InputDecoration(
              hintText: input.placeholder,
              hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
            ),
            onSubmitted: (_) => _confirm(context),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => _confirm(context),
              child: Text(input.confirmLabel),
            ),
          ),
        ],
      ),
    );
  }
}
