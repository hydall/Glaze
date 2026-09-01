import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_colors.dart';
import '../shell/nav_height_provider.dart';
import '../shell/shell_header_provider.dart';
import '../../features/settings/app_settings_provider.dart';
import 'glaze_background.dart';
import 'glaze_scaffold.dart';
import 'top_edge_blur.dart';

/// Corner radius of a modal sheet's top edge, kept constant at every height so
/// the sheet still reads as a sheet once expanded.
const double _kSheetCornerRadius = 20;

class SheetViewAction {
  final Widget icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final Color? color;

  const SheetViewAction({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color,
  });
}

class SheetViewTab {
  final String id;
  final String label;
  final IconData? icon;

  const SheetViewTab({required this.id, required this.label, this.icon});
}

/// Draggable bottom-sheet container.
///
/// Use [showModalBottomSheet] with [isScrollControlled: true] and
/// [backgroundColor: Colors.transparent] to present this widget.
/// It manages its own height: collapsed (~55 % of screen) or expanded
/// (full screen), with a swipe gesture and snap animation.
class SheetView extends ConsumerStatefulWidget {
  final String? title;
  final Widget? titleWidget;
  final bool showBack;
  final VoidCallback? onBack;
  final List<SheetViewAction> actions;
  final List<SheetViewTab> tabs;
  final String? activeTabId;
  final ValueChanged<String>? onTabSelected;
  final Widget? headerBottom;
  final Widget body;
  final Widget? floating;
  final Widget? floatingActionButton;
  final bool showHandle;
  final EdgeInsetsGeometry? bodyPadding;
  final bool startExpanded;
  final ScrollController? scrollController;

  /// Fraction of screen height for the collapsed snap point (0.0–1.0).
  /// When null, defaults to `min(0.55 * h, 500)`.
  final double? collapsedFraction;
  final bool fitContent;
  final bool showRouteBackground;
  final int? shellBranchIndex;
  final bool enableHeaderBlur;

  /// Whether a system/gesture back may dismiss the sheet outright.
  ///
  /// Set it to false while the body is showing an inner state of its own — a
  /// folder, a multi-selection, an inline editor — and the back event is handed
  /// to [onBack] instead, exactly like the header's back button, so the body
  /// unwinds one level per press before the sheet closes. Only consulted when
  /// the sheet is presented as a modal bottom sheet; as a fullscreen route back
  /// already goes through [onBack].
  ///
  /// Dragging the sheet down stays an outright dismissal either way.
  final bool canPop;

  const SheetView({
    super.key,
    this.title,
    this.titleWidget,
    this.showBack = false,
    this.onBack,
    this.actions = const [],
    this.tabs = const [],
    this.activeTabId,
    this.onTabSelected,
    this.headerBottom,
    required this.body,
    this.floating,
    this.floatingActionButton,
    this.showHandle = true,
    this.bodyPadding,
    this.startExpanded = false,
    this.scrollController,
    this.collapsedFraction,
    this.fitContent = false,
    this.showRouteBackground = true,
    this.shellBranchIndex,
    this.enableHeaderBlur = true,
    this.canPop = true,
  });

  @override
  ConsumerState<SheetView> createState() => _SheetViewState();
}

class _SheetViewState extends ConsumerState<SheetView>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  bool _heightInit = false;

  /// Current sheet height. A ValueNotifier (not setState) so that drag and
  /// snap-animation ticks only rebuild the few ValueListenableBuilders that
  /// depend on the height, instead of the entire sheet subtree every frame.
  final ValueNotifier<double> _heightN = ValueNotifier(0);
  double get _currentHeight => _heightN.value;
  set _currentHeight(double v) => _heightN.value = v;

  /// Fallback controller used when [SheetView.scrollController] is null.
  /// Ensures the [RawScrollbar] always has a valid controller attached,
  /// even if the child [Scrollable] uses [PrimaryScrollController] or its own.
  late final ScrollController _fallbackScrollController = ScrollController();

  /// Whether this SheetView is hosted inside [showModalBottomSheet]. When
  /// false (e.g. opened as a route via GoRouter), we behave as a regular
  /// fullscreen page: no drag handle, no resize, no drag-down dismiss.
  bool _inModalSheet = true;

  /// Branch whose persistent shell header this sheet is currently suppressing
  /// (only when presented as a fullscreen route, not a modal bottom sheet).
  int? _suppressedBranch;

  /// Whether the host already draws a title bar around this sheet — the
  /// desktop floating window. Then the sheet's own app-bar row (back button,
  /// title, actions) would be a second header inside the frame, so it is
  /// handed to the window's title bar instead of being drawn here.
  bool _hostDrawsChrome = false;

  /// Whether the header is drawn edge to edge with square corners, as the
  /// desktop shell draws a tab's. True for a sheet hosted in the right
  /// sidebar, where the inset pill of the phone layout left a floating bar
  /// adrift in a fixed column.
  bool _flushHeader = false;

  /// Whether the app-bar row belongs to this sheet's own header.
  bool get _ownsAppBar => !_hostDrawsChrome;

  /// Signature of the header content last published to a chrome-drawing host,
  /// so a rebuild only republishes when something visible actually changed —
  /// republishing unconditionally would rebuild the host, which rebuilds this
  /// sheet, which would republish again.
  String? _publishedChromeSignature;

  /// Cached so it can be used safely in [dispose].
  ShellHeaderRegistry? _headerRegistry;

  bool _keyboardOpen = false;

  /// Height the on-screen keyboard adds on top of [_heightN], capped at
  /// fullscreen.
  ///
  /// The sheet used to answer a keyboard by tweening its own height to
  /// fullscreen (and back on hide) over 350 ms. That tween ran *alongside* the
  /// keyboard's inset animation, which has its own duration and curve, so the
  /// body was resized twice per toggle by two desynchronised motions: content
  /// slid up with the inset, then again with the sheet, and any list that was
  /// scrolled to its end re-clamped its offset on every frame in between. It
  /// read as a flicker — most visibly in the Memory sheet's Summary tab, the
  /// one place in that sheet with text fields.
  ///
  /// Tracking the inset instead keeps the two in lockstep: the sheet grows by
  /// exactly what the keyboard covers, so the visible body neither shrinks nor
  /// is animated a second time, and it returns to its previous height as the
  /// keyboard retracts.
  double _kbLift = 0;

  /// Whether [_kbLift] is currently following the inset. Cleared by
  /// [_commitKeyboardLift] once the user takes the height over by hand.
  bool _kbAnchored = false;

  /// Sub-pixel slack for the measured header base. Subtracting the animated
  /// top pad back out of a measured height cannot be exact in binary floating
  /// point, and a base that wobbles in the last bits would republish the body's
  /// inset — and rebuild every body that reads it — on every frame of a resize.
  static const double _kHeaderBaseEpsilon = 0.01;

  /// Top padding the header was last built with, so [_measureHeader] can
  /// subtract exactly what that frame added instead of re-deriving it from a
  /// height that may already have ticked on — which made the padding-free base
  /// oscillate by a few pixels per frame during any resize.
  double _headerTopPad = 0;

  late AnimationController _ctrl;
  Animation<double>? _anim;

  final _headerKey = GlobalKey();
  double _headerH = 0;

  /// Measured header height minus the animated status-bar padding, so the
  /// body's top inset can follow the height notifier during drags/snaps
  /// without waiting for the next post-frame re-measure.
  double _headerBaseH = 0;

  double _dragStartY = 0;
  double _dragStartH = 0;

  bool get _effectiveShowHandle => widget.showHandle && _inModalSheet;

  double _collapsed(BuildContext ctx) {
    final h = MediaQuery.of(ctx).size.height;
    if (!_inModalSheet) return h;
    final f = widget.collapsedFraction;
    if (f != null) return h * f.clamp(0.0, 1.0);
    return h * 0.85;
  }

  double _full(BuildContext ctx) => MediaQuery.of(ctx).size.height;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _headerH = _estimateHeaderHeight();
    _headerBaseH = _headerH;
  }

  /// 0 → collapsed, 1 → fully expanded, for a given sheet height.
  double _t(double height) {
    final collapsed = _collapsed(context);
    final full = _full(context);
    if (full <= collapsed) return 0.0;
    return ((height - collapsed) / (full - collapsed)).clamp(0.0, 1.0);
  }

  /// Animated status-bar padding above the header (grows as the sheet
  /// approaches fullscreen).
  double _topPad(double height) =>
      MediaQueryData.fromView(View.of(context)).padding.top * _t(height);

  /// [base] plus the keyboard lift, never past fullscreen.
  double _lifted(double base) {
    if (_kbLift <= 0) return base;
    final full = _full(context);
    final lifted = base + _kbLift;
    return lifted > full ? full : lifted;
  }

  /// Folds the keyboard's share of the current height into [_heightN] and stops
  /// tracking the inset, so a drag or a snap started while the keyboard is up
  /// moves the sheet 1:1 instead of fighting the lift. The lift re-arms on the
  /// next time the keyboard comes up.
  void _commitKeyboardLift() {
    if (!_kbAnchored) return;
    final lifted = _lifted(_currentHeight);
    _kbAnchored = false;
    _kbLift = 0;
    _currentHeight = lifted;
    final expanded = lifted >= _full(context);
    if (expanded != _expanded) {
      setState(() => _expanded = expanded);
    }
  }

  double _estimateHeaderHeight() {
    if (!_hasHeader) {
      return 0;
    }
    double h = 0;
    if (_effectiveShowHandle) {
      h += 24;
    }
    if (_hasAppBarRow) {
      h += _inModalSheet ? 52 : 56;
    }
    if (widget.tabs.isNotEmpty) {
      h += 46;
    }
    if (widget.headerBottom != null) {
      h += 52;
    }
    return h;
  }

  void _measureHeader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) {
        return;
      }
      final h = box.size.height;
      // The measured box includes the animated top padding; keep the raw
      // value for the blur strip and the padding-free base for the body inset.
      final base = h - _headerTopPad;
      final baseMoved = (base - _headerBaseH).abs() > _kHeaderBaseEpsilon;
      if (h == _headerH && !baseMoved) return;
      setState(() {
        _headerH = h;
        // Only when the header's own content actually changed height: this is
        // the value the body's inset is published from.
        if (baseMoved) _headerBaseH = base;
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _inModalSheet = ModalRoute.of(context) is ModalBottomSheetRoute;
    // A modal bottom sheet is mounted on the root navigator, above any host,
    // so it always keeps its own header.
    _hostDrawsChrome = !_inModalSheet && DetachedShellHost.drawsChrome(context);
    // Hosted in the desktop right sidebar: a panel filling a fixed column, not
    // a sheet floating over a phone screen. Its header runs edge to edge with
    // square corners there, the way the desktop shell paints a tab's header —
    // the inset pill was left over from the phone layout.
    _flushHeader =
        !_inModalSheet && DetachedShellHost.of(context) && !_hostDrawsChrome;
    _syncHeaderSuppression();
    _publishChromeHeader();
    if (!_heightInit) {
      _currentHeight = (widget.startExpanded || !_inModalSheet)
          ? _full(context)
          : _collapsed(context);
      _expanded = widget.startExpanded || !_inModalSheet;
      _heightInit = true;
    }
  }

  /// When presented as a fullscreen route (not a modal bottom sheet), this
  /// sheet draws its own header, so it suppresses the shell's persistent header
  /// for the branch it lives in. A modal bottom sheet leaves the host screen's
  /// header visible behind it and must not suppress.
  void _syncHeaderSuppression() {
    // A sheet hosted in the desktop sidebar or floating window belongs to no
    // branch — suppressing "the current route's" branch there would hide the
    // header of the unrelated screen in the middle column.
    final branch = _inModalSheet || DetachedShellHost.of(context)
        ? null
        : widget.shellBranchIndex ?? _branchForCurrentRoute();
    if (branch == _suppressedBranch) return;
    _headerRegistry ??= ref.read(shellHeaderProvider.notifier);
    final notifier = _headerRegistry!;
    _suppressedBranch = branch;
    // Deferred: didChangeDependencies runs during the build phase, where
    // modifying a provider is forbidden.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (branch == null) {
        notifier.remove(this);
      } else if (mounted && _suppressedBranch == branch) {
        notifier.publish(this, branch, const ShellHeaderConfig(hidden: true));
      }
    });
  }

  /// Hands the header to a host that draws its own title bar (the desktop
  /// floating window), so the window shows this sheet's title and actions
  /// while the sheet itself draws no app-bar row.
  ///
  /// The claim goes under [kDetachedChromeBranch] rather than a real shell
  /// branch: the sheet is mounted outside the branch navigators, and the
  /// window resolves that pseudo-branch for exactly this purpose.
  void _publishChromeHeader() {
    // Cached for [dispose], where reading `ref` is unsafe.
    final ShellHeaderRegistry registry = ref.read(shellHeaderProvider.notifier);
    _headerRegistry = registry;
    if (!_hostDrawsChrome) {
      if (_publishedChromeSignature == null) return;
      _publishedChromeSignature = null;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => registry.remove(this),
      );
      return;
    }
    final signature = _chromeSignature();
    if (signature == _publishedChromeSignature) return;
    _publishedChromeSignature = signature;
    // Deferred: this runs during the build phase, where modifying a provider
    // is forbidden — and the host rebuilds on the claim, so it must not be
    // touched while it is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _publishedChromeSignature != signature) return;
      registry.publish(
        this,
        kDetachedChromeBranch,
        ShellHeaderConfig(
          title: widget.title,
          titleWidget: widget.titleWidget,
          actions: [
            for (var i = 0; i < widget.actions.length; i++)
              _ChromeHeaderAction(owner: this, index: i),
          ],
        ),
      );
    });
  }

  /// What the host's title bar shows, flattened. Only a change here is worth a
  /// republish; the callbacks themselves are read live by
  /// [_ChromeHeaderAction], so they never go stale between publishes.
  String _chromeSignature() {
    final buffer = StringBuffer(widget.title ?? '')
      ..write('|${widget.titleWidget?.runtimeType}');
    for (final action in widget.actions) {
      final icon = action.icon;
      buffer.write(
        '|${action.tooltip}|${action.color?.toARGB32()}'
        '|${icon is Icon ? icon.icon?.codePoint : icon.runtimeType}',
      );
    }
    return buffer.toString();
  }

  /// Branch index of the shell this sheet currently lives in, or null when the
  /// sheet is hosted outside GoRouter.
  ///
  /// A [SheetView] can be presented three ways: a GoRouter page (has a
  /// [GoRouterState]), a modal bottom sheet (handled by the caller), or a plain
  /// [MaterialPageRoute] pushed with `Navigator.push` — e.g. the lorebook
  /// editor opened from the lorebook list. In that last case there is no
  /// [GoRouterState] above the context and [GoRouterState.of] throws a
  /// [GoError] (this version of go_router has no `maybeOf`). There's no shell
  /// header to suppress there, so treat it as no branch instead of crashing.
  int? _branchForCurrentRoute() {
    try {
      return shellBranchForLocation(GoRouterState.of(context).uri.toString());
    } on GoError {
      return null;
    }
  }

  @override
  void didUpdateWidget(covariant SheetView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _publishChromeHeader();
  }

  @override
  void dispose() {
    final registry = _headerRegistry;
    if (registry != null &&
        (_suppressedBranch != null || _publishedChromeSignature != null)) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => registry.remove(this),
      );
    }
    _anim?.removeListener(_onTick);
    _ctrl.dispose();
    _fallbackScrollController.dispose();
    _heightN.dispose();
    super.dispose();
  }

  void _toggle() {
    if (widget.fitContent) return;
    // Commit first, so "expanded" means what the user sees when they tap the
    // handle: a sheet the keyboard has lifted to fullscreen collapses on the
    // first tap instead of swallowing it.
    _commitKeyboardLift();
    final target = _expanded ? _collapsed(context) : _full(context);
    _animateTo(target, expanding: !_expanded);
  }

  void _animateTo(double target, {required bool expanding}) {
    _commitKeyboardLift();
    final start = _currentHeight;
    _anim?.removeListener(_onTick);
    _anim = Tween(begin: start, end: target).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    )..addListener(_onTick);
    _ctrl.forward(from: 0);
    setState(() => _expanded = expanding);
  }

  // Height ticks go through the ValueNotifier only — no setState, so the
  // sheet subtree is not rebuilt on every animation/drag frame.
  void _onTick() => _currentHeight = _anim!.value;

  void _onDragStart(DragStartDetails d) {
    _commitKeyboardLift();
    _ctrl.stop();
    _anim?.removeListener(_onTick);
    _dragStartY = d.globalPosition.dy;
    _dragStartH = _currentHeight;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final dy = d.globalPosition.dy - _dragStartY;
    final minHeight = _collapsed(context) * 0.3;
    _currentHeight = (_dragStartH - dy).clamp(
      minHeight,
      widget.fitContent ? _collapsed(context) : _full(context),
    );
  }

  /// Closes the sheet after a drag-down. pop(), not maybePop(): flinging the
  /// sheet away is an explicit dismissal, so it closes the whole sheet even
  /// when [SheetView.canPop] is false because the body has an inner state a
  /// *back* press would step out of first.
  void _dismiss() => Navigator.of(context).pop();

  void _onDragEnd(DragEndDetails d) {
    final vy = d.velocity.pixelsPerSecond.dy;
    final collapsed = _collapsed(context);
    final full = _full(context);
    final mid = (collapsed + full) / 2;

    if (widget.fitContent) {
      if (vy > 600 || _currentHeight < collapsed * 0.6) {
        _dismiss();
      } else {
        _animateTo(collapsed, expanding: false);
      }
      return;
    }

    if (vy < -600 || (_currentHeight > mid && vy <= 600)) {
      _animateTo(full, expanding: true);
    } else if (vy > 600 || _currentHeight < collapsed * 0.6) {
      _dismiss();
    } else {
      _animateTo(
        _currentHeight >= mid ? full : collapsed,
        expanding: _currentHeight >= mid,
      );
    }
  }

  /// Whether this sheet draws the title/back/actions row itself. False when a
  /// chrome-drawing host renders it in its own title bar instead.
  bool get _hasAppBarRow =>
      _ownsAppBar &&
      (widget.title != null ||
          widget.titleWidget != null ||
          widget.showBack ||
          widget.actions.isNotEmpty);

  bool get _hasHeader =>
      _hasAppBarRow ||
      widget.tabs.isNotEmpty ||
      widget.headerBottom != null ||
      _effectiveShowHandle;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final batterySaver = ref.watch(
      appSettingsProvider.select((s) => s.value?.batterySaver ?? false),
    );
    final isKeyboardOpen = bottomInset > 0;

    if (isKeyboardOpen != _keyboardOpen) {
      _keyboardOpen = isKeyboardOpen;
      // A keyboard on its way up re-arms the lift; one that is gone drops it.
      // A fitContent sheet is sized by its body, and a fullscreen route has no
      // room to grow, so neither ever lifts.
      _kbAnchored = isKeyboardOpen && _inModalSheet && !widget.fitContent;
    }
    // Read every frame, not just on the open/close edge: the inset animates,
    // and the sheet has to follow it the whole way up and back down.
    _kbLift = _kbAnchored ? bottomInset : 0;

    if (!_inModalSheet) {
      if (_hasHeader) {
        _measureHeader();
      }

      // pop(), not maybePop(): this runs inside the PopScope below whose
      // canPop is false whenever showBack is true. maybePop() would re-enter
      // onPopInvokedWithResult and spin an unbounded microtask loop (freeze).
      final backHandler = widget.onBack ?? () => Navigator.of(context).pop();
      // When the sheet is rendered as a page route inside the Shell, the
      // GlassNavBar overlaps the body (Shell uses extendBody: true). Inject
      // its measured height into MediaQuery.padding.bottom so the body's
      // ListView can pick it up the same way it consumes paddingOf(...).top.
      // navHeight already includes the system safe-area inset (the nav bar
      // pads its own bottom by 16 + bottomPad), so use max() — not addition —
      // to avoid double-counting the inset on screens outside the Shell.
      final navHeight = ref.watch(navHeightProvider);

      final routeScaffold = Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            Positioned.fill(
              child: Builder(
                builder: (context) {
                  final mediaQuery = MediaQuery.of(context);
                  final extraTop = _hasHeader
                      ? (mediaQuery.padding.top + 10 + _headerH)
                      : mediaQuery.padding.top;
                  final newPadding = mediaQuery.padding.copyWith(
                    top: extraTop,
                    bottom: navHeight > mediaQuery.padding.bottom
                        ? navHeight
                        : mediaQuery.padding.bottom,
                  );

                  final innerChild = Padding(
                    padding: widget.bodyPadding ?? EdgeInsets.zero,
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: isKeyboardOpen ? bottomInset + 10 : 0,
                      ),
                      child: widget.body,
                    ),
                  );

                  return TopEdgeBlur(
                    enabled: _hasHeader && !batterySaver,
                    height: extraTop + 8,
                    sigma: 24,
                    tintColor: context.cs.surface.withValues(alpha: 0.88),
                    child: MediaQuery(
                      data: mediaQuery.copyWith(padding: newPadding),
                      child: _MaybeScrollbar(
                        controller:
                            widget.scrollController ??
                            _fallbackScrollController,
                        child: innerChild,
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_hasHeader)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: _flushHeader
                        ? EdgeInsets.zero
                        : const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: KeyedSubtree(
                      key: _headerKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_hasAppBarRow)
                            GlazeAppBar(
                              title: widget.title,
                              titleWidget: widget.titleWidget,
                              showBack: widget.showBack,
                              onBack: widget.onBack,
                              borderRadius: _flushHeader
                                  ? BorderRadius.zero
                                  : const BorderRadius.all(Radius.circular(20)),
                              actions: widget.actions.map((action) {
                                return _HeaderIconButton(
                                  onPressed: action.onPressed,
                                  tooltip: action.tooltip,
                                  foregroundColor:
                                      action.color ?? context.cs.primary,
                                  child: action.icon,
                                );
                              }).toList(),
                            ),
                          if (widget.tabs.isNotEmpty)
                            Padding(
                              // The outer gutter is dropped when flush, so the
                              // rows below the app bar carry their own.
                              padding: EdgeInsets.only(
                                top: 12,
                                left: _flushHeader ? 16 : 0,
                                right: _flushHeader ? 16 : 0,
                              ),
                              child: Row(
                                children: widget.tabs
                                    .map(
                                      (tab) => Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                          ),
                                          child: _SheetTabButton(
                                            tab: tab,
                                            active:
                                                widget.activeTabId == tab.id,
                                            onTap: widget.onTabSelected == null
                                                ? null
                                                : () => widget.onTabSelected!(
                                                    tab.id,
                                                  ),
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          if (widget.headerBottom != null)
                            Padding(
                              padding: EdgeInsets.only(
                                top: 12,
                                left: _flushHeader ? 16 : 0,
                                right: _flushHeader ? 16 : 0,
                              ),
                              child: widget.headerBottom!,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (widget.floating != null)
              Positioned.fill(child: widget.floating!),
            if (widget.floatingActionButton != null)
              Positioned(
                right: 16,
                bottom:
                    16 + MediaQuery.of(context).padding.bottom + bottomInset,
                child: widget.floatingActionButton!,
              ),
          ],
        ),
      );

      return PopScope(
        canPop: !widget.showBack,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          backHandler();
        },
        child: widget.showRouteBackground
            ? GlazeBackground(child: routeScaffold)
            : routeScaffold,
      );
    }

    if (_hasHeader) {
      _measureHeader();
    }

    // Solid opaque background. The previous surface-alpha-0.8 +
    // sigma-20 BackdropFilter variant cost a full-width backdrop blur on
    // every frame the sheet moved or resized, and over dark themes the 20%
    // show-through read as a solid fill anyway.
    final content = _sheetContent(
      context,
      bottomInset,
      batterySaver,
      opaque: true,
    );

    // pop(), not maybePop(): a body that blocks the pop (canPop false) handles
    // the back event in onBack, and maybePop() would re-enter this callback.
    final sheetBackHandler = widget.onBack ?? () => Navigator.of(context).pop();

    return PopScope(
      canPop: widget.canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        sheetBackHandler();
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: widget.fitContent
              ? _full(context) * 0.95
              : double.infinity,
        ),
        child: ValueListenableBuilder<double>(
          valueListenable: _heightN,
          child: content,
          builder: (context, height, child) {
            return SizedBox(
              height: widget.fitContent ? null : _lifted(height),
              child: ClipRRect(
                // Constant, so the sheet keeps its rounded top edge when
                // expanded to full height. It used to taper to 0 on the way up,
                // which made a sheet opened by tapping the handle end as a
                // square-cornered slab flush against the status bar.
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(_kSheetCornerRadius),
                ),
                child: child,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _sheetContent(
    BuildContext context,
    double bottomInset,
    bool batterySaver, {
    bool opaque = false,
  }) {
    final isKeyboardOpen = _keyboardOpen;
    return Container(
      color: context.cs.surface.withValues(alpha: opaque ? 1.0 : 0.8),
      child: Stack(
        children: [
          widget.fitContent
              ? _buildBodyChild(
                  context,
                  bottomInset,
                  isKeyboardOpen,
                  batterySaver,
                )
              : Positioned.fill(
                  child: _buildBodyChild(
                    context,
                    bottomInset,
                    isKeyboardOpen,
                    batterySaver,
                  ),
                ),

          // Interactive header — rendered above the gradient so buttons
          // and drag handle are unobscured and fully hittable.
          if (_hasHeader)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: KeyedSubtree(
                key: _headerKey,
                child: ValueListenableBuilder<double>(
                  valueListenable: _heightN,
                  child: _SheetViewHeader(
                    showAppBar: _hasAppBarRow,
                    title: widget.title,
                    titleWidget: widget.titleWidget,
                    showBack: widget.showBack,
                    onBack: widget.onBack,
                    actions: widget.actions,
                    tabs: widget.tabs,
                    activeTabId: widget.activeTabId,
                    onTabSelected: widget.onTabSelected,
                    headerBottom: widget.headerBottom,
                    showHandle: _effectiveShowHandle,
                    expanded: _expanded,
                    onHandleTap: _toggle,
                    onDragStart: widget.fitContent ? null : _onDragStart,
                    onDragUpdate: widget.fitContent ? null : _onDragUpdate,
                    onDragEnd: widget.fitContent ? null : _onDragEnd,
                  ),
                  builder: (context, height, header) {
                    // Recorded so _measureHeader subtracts exactly what this
                    // frame added.
                    _headerTopPad = _topPad(_lifted(height));
                    return Padding(
                      padding: EdgeInsets.only(top: _headerTopPad),
                      child: header,
                    );
                  },
                ),
              ),
            ),
          if (widget.floating != null) Positioned.fill(child: widget.floating!),
          if (widget.floatingActionButton != null)
            Positioned(
              right: 16,
              bottom: 16 + MediaQuery.of(context).padding.bottom + bottomInset,
              child: widget.floatingActionButton!,
            ),
        ],
      ),
    );
  }

  Widget _buildBodyChild(
    BuildContext context,
    double bottomInset,
    bool isKeyboardOpen,
    bool batterySaver,
  ) {
    // TopEdgeBlur stays mounted permanently and is merely toggled via
    // `enabled`, so the scroll body's Element (and any focused TextField's
    // FocusNode) survives interaction/battery-saver transitions without
    // GlobalKey tricks.
    return TopEdgeBlur(
      enabled: widget.enableHeaderBlur && _hasHeader && !batterySaver,
      height: _headerH + 8,
      sigma: 24,
      tintColor: context.cs.surface.withValues(alpha: 0.88),
      child: _buildScrollConfig(context, bottomInset, isKeyboardOpen),
    );
  }

  Widget _buildScrollConfig(
    BuildContext context,
    double bottomInset,
    bool isKeyboardOpen,
  ) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: Builder(
        builder: (context) {
          final mediaQuery = MediaQuery.of(context);

          // The nav-bar inset is delivered through MediaQuery.padding.bottom
          // (below), not as an outer Padding around the body. That way a
          // scrollable body (ListView &co, which auto-consumes the inset, or a
          // body that reads MediaQuery.paddingOf(context).bottom itself) treats
          // it as *scroll content* padding: the viewport keeps reaching the
          // sheet's bottom edge, so list rows stay visible scrolling behind the
          // nav bar, while the last row still rests above it. An outer Padding
          // instead shrinks the viewport and leaves a dead strip below the
          // list — and double-counts for bodies that already read the inset.
          // fitContent sheets keep the bare inset (their bodies add their own
          // margin); other sheets get inset + a small margin.
          final navInset = widget.fitContent
              ? mediaQuery.padding.bottom
              : mediaQuery.padding.bottom + 16;

          final innerChild = Padding(
            padding: widget.bodyPadding ?? EdgeInsets.zero,
            // The keyboard is a hard occlusion, so it stays an outer inset:
            // content is lifted wholesale above it (a dead strip behind the
            // keyboard is correct). The nav-bar inset does not — see above.
            child: Padding(
              padding: EdgeInsets.only(
                bottom: isKeyboardOpen ? bottomInset + 16 : 0,
              ),
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: widget.fitContent ? 1.0 : null,
                child: RepaintBoundary(
                  child: SizedBox(width: double.infinity, child: widget.body),
                ),
              ),
            ),
          );

          final scrollChild = _MaybeScrollbar(
            controller: widget.scrollController ?? _fallbackScrollController,
            child: innerChild,
          );

          // The header inset the body reads stays put; the status-bar pad
          // that grows as the sheet approaches fullscreen is applied around it
          // as an outer inset instead of being folded into it.
          //
          // Folded in, it changed the MediaQuery on every frame of a resize,
          // and every body that reads the inset rebuilt with it — for a big
          // form whose list is built eagerly (the API sheet) that is a full
          // widget-tree rebuild per frame of the keyboard animation, which is
          // what dropped frames there. As an outer inset it costs the relayout
          // the body pays anyway, and nothing rebuilds. The body still starts
          // at the same place: the header carries the same pad above its own
          // content.
          final insetBody = MediaQuery(
            data: mediaQuery.copyWith(
              padding: mediaQuery.padding.copyWith(
                top: _hasHeader ? _headerBaseH : 0.0,
                bottom: navInset,
              ),
            ),
            child: scrollChild,
          );

          return ValueListenableBuilder<double>(
            valueListenable: _heightN,
            child: insetBody,
            builder: (context, height, child) => Padding(
              padding: EdgeInsets.only(top: _topPad(_lifted(height))),
              child: child!,
            ),
          );
        },
      ),
    );
  }
}

class _SheetViewHeader extends StatelessWidget {
  /// False when the host draws the title/back/actions row itself, leaving this
  /// header with only the handle, tabs and [headerBottom].
  final bool showAppBar;
  final String? title;
  final Widget? titleWidget;
  final bool showBack;
  final VoidCallback? onBack;
  final List<SheetViewAction> actions;
  final List<SheetViewTab> tabs;
  final String? activeTabId;
  final ValueChanged<String>? onTabSelected;
  final Widget? headerBottom;
  final bool showHandle;
  final bool expanded;
  final VoidCallback onHandleTap;
  final GestureDragStartCallback? onDragStart;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;

  const _SheetViewHeader({
    required this.showAppBar,
    this.title,
    this.titleWidget,
    required this.showBack,
    this.onBack,
    required this.actions,
    required this.tabs,
    this.activeTabId,
    this.onTabSelected,
    this.headerBottom,
    required this.showHandle,
    required this.expanded,
    required this.onHandleTap,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showHandle)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onHandleTap,
            onVerticalDragStart: onDragStart,
            onVerticalDragUpdate: onDragUpdate,
            onVerticalDragEnd: onDragEnd,
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    width: expanded ? 24.0 : 36.0,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(
                        alpha: expanded ? 0.6 : 0.35,
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (showAppBar)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                // No reserved slot when there is no back button: the title is
                // left-aligned anyway, so an empty 40pt gap in front of it only
                // reads as a misalignment.
                if (showBack) ...[
                  _HeaderIconButton(
                    onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                    child: Icon(
                      Icons.arrow_back,
                      size: 20,
                      color: context.cs.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child:
                      titleWidget ??
                      (title != null
                          ? Text(
                              title!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: context.cs.onSurface,
                              ),
                            )
                          : const SizedBox.shrink()),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: actions
                      .map(
                        (action) => Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: _HeaderIconButton(
                            tooltip: action.tooltip,
                            onPressed: action.onPressed,
                            foregroundColor: action.color ?? context.cs.primary,
                            child: action.icon,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
        if (tabs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: tabs
                  .map(
                    (tab) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: _SheetTabButton(
                          tab: tab,
                          active: activeTabId == tab.id,
                          onTap: onTabSelected == null
                              ? null
                              : () => onTabSelected!(tab.id),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        if (headerBottom != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: headerBottom!,
          ),
      ],
    );
  }
}

/// One of the sheet's actions, rendered in a chrome-drawing host's title bar.
///
/// It keeps the owning state rather than the action itself, and reads the
/// action back on every build: the published claim is only refreshed when the
/// header's visible signature changes, so a captured callback could otherwise
/// outlive the build that created it.
class _ChromeHeaderAction extends StatelessWidget {
  final _SheetViewState owner;
  final int index;

  const _ChromeHeaderAction({required this.owner, required this.index});

  @override
  Widget build(BuildContext context) {
    final actions = owner.widget.actions;
    if (index >= actions.length) return const SizedBox.shrink();
    final action = actions[index];
    return _HeaderIconButton(
      tooltip: action.tooltip,
      onPressed: () {
        final current = owner.widget.actions;
        if (index < current.length) current[index].onPressed();
      },
      foregroundColor: action.color ?? context.cs.primary,
      child: action.icon,
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onPressed;
  final String? tooltip;
  final Color? foregroundColor;

  const _HeaderIconButton({
    required this.child,
    required this.onPressed,
    this.tooltip,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final fg = foregroundColor ?? context.cs.primary;
    final button = Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 40,
          height: 40,
          child: IconTheme(
            data: IconThemeData(color: fg),
            child: DefaultTextStyle(
              style: TextStyle(color: fg),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );

    if (tooltip == null || tooltip!.isEmpty) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

class _SheetTabButton extends StatelessWidget {
  final SheetViewTab tab;
  final bool active;
  final VoidCallback? onTap;

  const _SheetTabButton({required this.tab, required this.active, this.onTap});

  @override
  Widget build(BuildContext context) {
    final foreground = active
        ? context.cs.primary
        : context.cs.onSurfaceVariant;
    return Material(
      color: active
          ? context.cs.primary.withValues(alpha: 0.12)
          : Colors.white.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active
                  ? context.cs.primary.withValues(alpha: 0.28)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (tab.icon != null) ...[
                Icon(tab.icon, size: 18, color: foreground),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  tab.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wraps [child] in a [RawScrollbar] with a persistent thumb, but only
/// when the subtree actually contains a [Scrollable] using the same
/// [controller]. If the child has no matching scrollable (e.g. a static
/// placeholder while async data is loading), the bar is omitted to avoid
/// Flutter's "no ScrollPosition attached" assertion in debug builds.
class _MaybeScrollbar extends StatefulWidget {
  final ScrollController controller;
  final Widget child;
  const _MaybeScrollbar({required this.controller, required this.child});

  @override
  State<_MaybeScrollbar> createState() => _MaybeScrollbarState();
}

class _MaybeScrollbarState extends State<_MaybeScrollbar> {
  bool _hasAttached = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChange);
    _sync();
  }

  @override
  void didUpdateWidget(covariant _MaybeScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChange);
      widget.controller.addListener(_onControllerChange);
      _sync();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    super.dispose();
  }

  void _onControllerChange() => _sync();

  void _sync() {
    final has = widget.controller.hasClients;
    if (has != _hasAttached) {
      if (mounted) setState(() => _hasAttached = has);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasAttached) return widget.child;
    return RawScrollbar(
      controller: widget.controller,
      thumbVisibility: true,
      thickness: 6,
      radius: const Radius.circular(3),
      child: widget.child,
    );
  }
}
