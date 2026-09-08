import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../shell/shell_header_provider.dart';
import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'glaze_background.dart';

/// Scaffold with a floating glassmorphic header — use for screens OUTSIDE
/// the shell (character editor, chat screen, etc.) that need a back button.
///
/// Screens inside the shell (history, character list, menu) build their own
/// header inline in their body since they share the shell's bottom nav.
class GlazeScaffold extends StatelessWidget {
  final String? title;
  final Widget? titleWidget;
  final Widget body;
  final List<Widget>? actions;
  final bool showBack;
  final VoidCallback? onBack;
  final bool extendBodyBehindHeader;
  final bool resizeToAvoidBottomInset;
  final bool hideHeader;
  final bool showBackground;

  /// Set for the chat screen, whose body is a full-screen `InAppWebView`. The
  /// floating header then drops its Flutter blur and lets an in-WebView CSS
  /// strip reproduce it (see [GlassSurface.blurViaWebView]).
  final bool headerBlurViaWebView;

  /// When true, this scaffold does not draw its own floating header. Instead it
  /// publishes its title/actions/back into the shell's persistent header (see
  /// [shellHeaderProvider]) and reserves the same vertical space. Only set this
  /// for screens that live inside a shell branch (sub-routes of a bottom-nav
  /// tab); standalone pushed routes keep their own header.
  final bool useShellHeader;

  /// The shell branch (bottom-nav tab) this screen belongs to. Required when
  /// [useShellHeader] is true.
  final int? headerBranchIndex;

  const GlazeScaffold({
    super.key,
    this.title,
    this.titleWidget,
    required this.body,
    this.actions,
    this.showBack = true,
    this.onBack,
    this.extendBodyBehindHeader = false,
    this.resizeToAvoidBottomInset = true,
    this.hideHeader = false,
    this.showBackground = true,
    this.useShellHeader = false,
    this.headerBranchIndex,
    this.headerBlurViaWebView = false,
  });

  @override
  Widget build(BuildContext context) {
    final backHandler = onBack ?? () => Navigator.of(context).maybePop();
    final isIosLikeTargetPlatform =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    // Use GoRouter's declarative stack, NOT Navigator.canPop(). During a
    // `go('/chat/...')` transition the outgoing route is still in the
    // Navigator's animation history, so `Navigator.canPop()` transiently
    // returns true and that stale value gets baked into `PopScope.canPop`.
    // On iOS that let the edge-swipe perform a real pop of the only remaining
    // page, emptying the root navigator and closing the app. GoRouter's match
    // list is updated synchronously on `go` (a top-level route reports false),
    // while genuinely pushed routes still report true so the iOS swipe-back
    // keeps working there.
    final navigatorCanPop = GoRouter.of(context).canPop();

    final header = SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: GlazeAppBar(
          title: title,
          titleWidget: titleWidget,
          actions: actions,
          showBack: showBack,
          onBack: backHandler,
          blurViaWebView: headerBlurViaWebView,
        ),
      ),
    );

    final animatedHeader = AnimatedSlide(
      offset: hideHeader ? const Offset(0, -1.5) : Offset.zero,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: hideHeader ? 0.0 : 1.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        child: header,
      ),
    );

    // When delegating to the shell's persistent header, reserve the same space
    // the local header would occupy but draw nothing — the shell paints the
    // header on top.
    final headerSlot = useShellHeader
        ? const SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: SizedBox(height: 56),
            ),
          )
        : animatedHeader;

    final scaffold = PopScope(
      canPop: isIosLikeTargetPlatform ? navigatorCanPop : !showBack,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        backHandler();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        body: extendBodyBehindHeader
            ? Stack(
                children: [
                  Positioned.fill(child: body),
                  Positioned(top: 0, left: 0, right: 0, child: headerSlot),
                ],
              )
            : Column(
                children: [
                  headerSlot,
                  Expanded(
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      child: body,
                    ),
                  ),
                ],
              ),
      ),
    );

    final withBackground = showBackground
        ? GlazeBackground(
            child: scaffold,
          )
        : scaffold;

    if (!useShellHeader) return withBackground;

    return _ShellHeaderPublisher(
      branchIndex: headerBranchIndex ?? 0,
      config: ShellHeaderConfig(
        title: title,
        titleWidget: titleWidget,
        actions: actions,
        showBack: showBack,
        onBack: backHandler,
      ),
      child: withBackground,
    );
  }
}

/// Publishes a [ShellHeaderConfig] into [shellHeaderProvider] for as long as it
/// is mounted, re-publishing when the config changes. Used by [GlazeScaffold]
/// in `useShellHeader` mode. Mutations are deferred past the build phase.
class _ShellHeaderPublisher extends ConsumerStatefulWidget {
  final int branchIndex;
  final ShellHeaderConfig config;
  final Widget child;

  const _ShellHeaderPublisher({
    required this.branchIndex,
    required this.config,
    required this.child,
  });

  @override
  ConsumerState<_ShellHeaderPublisher> createState() =>
      _ShellHeaderPublisherState();
}

class _ShellHeaderPublisherState extends ConsumerState<_ShellHeaderPublisher> {
  // Cached so it can be used safely in [dispose].
  ShellHeaderRegistry? _registry;

  void _publish() {
    if (!mounted) return;
    _registry?.publish(this, widget.branchIndex, widget.config);
  }

  @override
  void initState() {
    super.initState();
    _registry = ref.read(shellHeaderProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) => _publish());
  }

  @override
  void didUpdateWidget(covariant _ShellHeaderPublisher oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _publish());
  }

  @override
  void dispose() {
    final registry = _registry;
    WidgetsBinding.instance.addPostFrameCallback((_) => registry?.remove(this));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Standalone floating glassmorphic app bar — use this directly when you
/// need to embed the header inside a body Column (e.g. shell-tab screens).
class GlazeAppBar extends ConsumerWidget {
  final String? title;
  final Widget? titleWidget;
  final List<Widget>? actions;
  final bool showBack;
  final VoidCallback? onBack;
  final Widget? leading;
  final BorderRadius borderRadius;

  /// When the header floats over the chat WebView its blur is reproduced by a
  /// CSS strip inside the WebView (see [GlassSurface.blurViaWebView]); the
  /// Flutter BackdropFilter is then dropped. Only the chat header sets this —
  /// standalone shell-tab headers keep their own blur.
  final bool blurViaWebView;

  const GlazeAppBar({
    super.key,
    this.title,
    this.titleWidget,
    this.actions,
    this.showBack = false,
    this.onBack,
    this.leading,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.blurViaWebView = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GlassSurface(
      enableRipple: true,
      blurViaWebView: blurViaWebView,
      borderRadius: borderRadius,
      border: Border.all(color: context.cs.outlineVariant),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            // Left: back button OR logo
            SizedBox(
              width: 52,
              child: showBack
                  ? IconButton(
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 20,
                      ),
                      color: context.cs.primary,
                      onPressed:
                          onBack ?? () => Navigator.of(context).maybePop(),
                    )
                  : leading ??
                        Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: _GlazeLogo(),
                        ),
            ),
            // Title
            Expanded(
              child:
                  titleWidget ??
                  (title != null
                      ? Text(
                          title!,
                          style: TextStyle(
                            color: context.cs.onSurface,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        )
                      : const SizedBox.shrink()),
            ),
            // Right actions
            if (actions != null)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: actions!,
                ),
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

/// Glaze logo mark — styled "G" matching the brand accent colour.
class _GlazeLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(
      '''<svg viewBox="0 0 600 600" xmlns="http://www.w3.org/2000/svg"><g transform="translate(0,600) scale(0.1,-0.1)" fill="currentColor"><path d="M2799 4916 c-2 -2 -33 -7 -69 -10 -36 -3 -76 -8 -90 -11 -14 -2 -65 -12 -115 -21 -49 -9 -116 -25 -147 -35 -32 -11 -63 -19 -71 -19 -7 0 -31 -8 -53 -19 -21 -10 -55 -22 -74 -26 -38 -8 -146 -60 -285 -136 -43 -23 -118 -79 -123 -91 -2 -5 -10 -8 -18 -8 -8 0 -14 -4 -14 -10 0 -5 -6 -10 -13 -10 -8 0 -27 -13 -43 -30 -16 -16 -34 -30 -40 -30 -7 0 -30 -20 -52 -45 -23 -25 -45 -47 -49 -48 -12 -3 -133 -139 -133 -149 0 -5 -5 -6 -10 -3 -6 3 -10 1 -10 -6 0 -6 -36 -59 -80 -117 -44 -58 -80 -111 -80 -119 0 -7 -4 -13 -9 -13 -5 0 -12 -11 -15 -24 -3 -14 -12 -31 -19 -38 -6 -7 -17 -24 -24 -38 -6 -14 -30 -64 -52 -111 -23 -48 -41 -93 -41 -101 0 -8 -4 -18 -9 -23 -4 -6 -14 -32 -20 -60 -7 -27 -21 -72 -31 -100 -17 -43 -27 -94 -55 -255 -17 -100 -27 -293 -22 -435 6 -160 38 -417 56 -439 7 -9 17 -42 26 -86 11 -56 30 -120 41 -137 8 -12 14 -31 14 -41 0 -10 4 -22 8 -28 5 -5 17 -29 26 -54 36 -92 154 -293 216 -367 5 -7 10 -16 10 -22 0 -5 7 -11 15 -15 8 -3 15 -12 15 -20 0 -9 38 -54 85 -101 47 -47 85 -90 85 -96 0 -5 4 -9 9 -9 5 0 16 -6 23 -13 7 -6 38 -32 67 -57 30 -25 65 -54 77 -65 49 -43 92 -75 102 -75 5 0 15 -7 22 -15 7 -9 15 -13 18 -11 3 3 18 -4 34 -15 36 -26 190 -103 201 -101 4 1 7 -3 7 -8 0 -6 9 -10 19 -10 11 0 21 -4 23 -8 2 -6 140 -56 183 -67 6 -1 23 -7 38 -13 15 -7 51 -16 80 -21 29 -6 72 -14 97 -19 25 -6 68 -13 95 -16 28 -4 82 -11 120 -17 46 -7 343 -9 855 -7 725 3 787 4 815 20 17 10 37 18 46 18 20 0 95 36 119 58 11 9 32 28 47 42 15 14 31 24 35 23 5 -2 8 3 8 11 0 7 11 24 23 37 51 52 100 169 108 254 2 28 4 399 4 825 0 774 0 775 -23 858 -32 115 -48 143 -140 238 -63 65 -171 122 -272 143 -37 8 -1228 5 -1278 -3 -23 -4 -61 -14 -84 -22 -47 -16 -154 -86 -181 -118 -10 -11 -15 -15 -11 -7 5 9 3 12 -4 7 -7 -4 -12 -13 -12 -21 0 -7 -6 -20 -13 -27 -7 -7 -27 -37 -45 -66 -58 -94 -77 -226 -52 -362 10 -55 38 -144 40 -125 0 6 7 -3 15 -20 7 -16 27 -45 44 -64 17 -18 31 -37 31 -40 0 -4 15 -15 33 -26 17 -10 37 -23 42 -27 100 -81 181 -96 545 -97 266 -2 296 -3 308 -19 18 -24 13 -435 -6 -454 -9 -9 -112 -12 -460 -10 -246 1 -472 6 -502 11 -30 5 -58 7 -62 4 -5 -2 -8 -1 -8 4 0 4 -13 9 -30 10 -16 1 -51 11 -77 22 -26 10 -63 25 -82 32 -18 7 -49 23 -68 36 -19 13 -38 21 -43 18 -4 -3 -10 -2 -12 3 -1 4 -25 23 -53 42 -60 42 -181 163 -201 202 -8 15 -19 28 -23 28 -5 0 -12 13 -16 30 -4 16 -11 30 -16 30 -5 0 -9 6 -9 14 0 8 -3 16 -7 18 -13 5 -43 68 -43 88 0 10 -4 20 -9 22 -22 7 -70 238 -76 366 -9 172 11 297 68 432 5 14 12 36 14 49 2 13 11 30 19 38 7 8 14 23 14 34 0 11 5 17 10 14 6 -3 10 1 10 9 0 8 6 21 13 28 8 7 26 32 40 55 14 23 49 65 76 95 28 29 51 56 51 61 0 4 4 7 10 7 10 0 38 21 76 58 13 13 28 21 33 18 4 -3 16 3 26 14 10 11 24 20 32 20 7 0 13 5 13 11 0 6 7 9 15 6 8 -4 17 -2 20 3 4 6 15 10 26 10 10 0 19 4 19 8 0 8 81 37 165 58 74 20 230 24 910 27 704 2 775 4 823 20 94 32 208 99 218 130 3 9 12 17 20 17 8 0 14 4 14 8 0 5 8 17 18 28 36 42 70 110 88 177 26 100 8 307 -32 358 -6 8 -17 29 -25 47 -8 17 -17 32 -21 32 -5 0 -8 4 -8 9 0 11 -77 91 -88 91 -4 0 -19 11 -34 25 -15 14 -29 25 -30 26 -19 0 -48 14 -48 22 0 6 -3 8 -6 4 -3 -3 -27 4 -52 16 -47 22 -50 22 -842 25 -438 2 -798 1 -801 -2z" /></g></svg>''',
      width: 32,
      height: 32,
      fit: BoxFit.contain,
      colorFilter: ColorFilter.mode(context.cs.primary, BlendMode.srcIn),
    );
  }
}

// ─── Shared ghost pill button ──────────────────────────────────────────────

/// Accent-tinted ghost pill button — matches Glaze's `tabs-add-btn` style.
class GlazePillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const GlazePillButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: context.cs.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: context.cs.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.cs.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
