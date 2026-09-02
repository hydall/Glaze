import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

/// Immutable description of what a shell screen wants the persistent header to
/// show. Screens publish this into [shellHeaderProvider]; [ShellScreen] renders
/// a single header from the topmost config of the active branch.
@immutable
class ShellHeaderConfig {
  final String? title;
  final Widget? titleWidget;
  final List<Widget>? actions;
  final bool showBack;
  final VoidCallback? onBack;

  /// Replaces the header's leading slot — the Glaze logo by default. Screens
  /// that temporarily stop being "a tab" set it (the dialogs list swaps in a
  /// close button while a multi-selection is running); ignored when
  /// [showBack] draws a back button there instead.
  final Widget? leading;

  /// Optional extra row rendered directly under the app bar (e.g. the Chats
  /// "Filter: …" chip).
  final Widget? below;

  /// When true the persistent header renders nothing for this claim — used by
  /// fullscreen route-mode sheets that draw their own header (see [SheetView]),
  /// so the shell header does not float on top of them.
  final bool hidden;

  const ShellHeaderConfig({
    this.title,
    this.titleWidget,
    this.actions,
    this.showBack = false,
    this.onBack,
    this.leading,
    this.below,
    this.hidden = false,
  });
}

/// Maps a GoRouter location to the shell branch (bottom-nav tab) it belongs to,
/// or null if it is not one of the four persistent-header branches.
int? shellBranchForLocation(String location) {
  final segments = Uri.parse(location).pathSegments;
  if (segments.isEmpty) return 0; // '/'
  switch (segments.first) {
    case 'characters':
      return 1;
    case 'tools':
      return 2;
    case 'menu':
      return 3;
    default:
      return null;
  }
}

/// A single screen's claim on the persistent header.
@immutable
class ShellHeaderEntry {
  /// Stable identity of the publishing screen — used as the [AnimatedSwitcher]
  /// key so navigation between screens cross-fades, but a screen updating its
  /// own title (e.g. typing in search) does not.
  final Object key;

  /// Which shell branch (bottom-nav tab) this screen belongs to.
  final int branchIndex;

  /// Monotonic registration order. Within a branch the highest order wins,
  /// so a pushed sub-screen (registered later) owns the header until it pops.
  final int order;

  final ShellHeaderConfig config;

  const ShellHeaderEntry({
    required this.key,
    required this.branchIndex,
    required this.order,
    required this.config,
  });

  ShellHeaderEntry withConfig(ShellHeaderConfig config) => ShellHeaderEntry(
    key: key,
    branchIndex: branchIndex,
    order: order,
    config: config,
  );
}

/// Registry of every shell screen's header claim. Mutated only from outside the
/// build phase (screen `initState` post-frame, event handlers, `dispose`).
class ShellHeaderRegistry extends Notifier<List<ShellHeaderEntry>> {
  int _orderCounter = 0;
  bool _disposed = false;

  @override
  List<ShellHeaderEntry> build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const [];
  }

  /// Inserts or updates the entry for [key]. Order is assigned once, on first
  /// publish, so a screen keeps its depth even as its config changes.
  void publish(Object key, int branchIndex, ShellHeaderConfig config) {
    if (_disposed) return;
    final idx = state.indexWhere((e) => e.key == key);
    if (idx >= 0) {
      final next = [...state];
      next[idx] = next[idx].withConfig(config);
      state = next;
    } else {
      state = [
        ...state,
        ShellHeaderEntry(
          key: key,
          branchIndex: branchIndex,
          order: _orderCounter++,
          config: config,
        ),
      ];
    }
  }

  void remove(Object key) {
    if (_disposed) return;
    if (state.any((e) => e.key == key)) {
      state = state.where((e) => e.key != key).toList();
    }
  }
}

final shellHeaderProvider =
    NotifierProvider<ShellHeaderRegistry, List<ShellHeaderEntry>>(
      ShellHeaderRegistry.new,
    );

/// Per-branch flag that slides the persistent header (and any screen chrome
/// meant to travel with it, e.g. the character list's tabs row) in and out of
/// view as the branch's list scrolls — the shell-level equivalent of the chat
/// screen's `_isHeaderHidden`. Screens toggle it from a scroll listener; the
/// header and the screen both read it so they animate together. Visible (false)
/// by default and keyed by branch so tabs don't affect each other.
final shellHeaderHiddenProvider = StateProvider.family<bool, int>(
  (ref, branchIndex) => false,
);

/// Resolves the header that should be shown for [branchIndex]: the topmost
/// (highest-order) claim belonging to that branch, or null if none.
ShellHeaderEntry? resolveShellHeader(
  List<ShellHeaderEntry> entries,
  int branchIndex,
) {
  ShellHeaderEntry? best;
  for (final e in entries) {
    if (e.branchIndex != branchIndex) continue;
    if (best == null || e.order > best.order) best = e;
  }
  return best;
}

/// Marks a subtree that is hosted *outside* the shell's branch navigators —
/// the desktop right sidebar's tool panel and the desktop floating window.
///
/// Screens there are the same widgets the router mounts in the middle column,
/// and a [SheetView] among them would otherwise suppress the header of
/// whichever branch the middle column happens to be showing: opening API
/// settings in the sidebar blanked the character list's header behind it.
class DetachedShellHost extends InheritedWidget {
  /// Whether the host draws header chrome of its own — the desktop floating
  /// window's title bar, with the window's back/close buttons in it.
  ///
  /// A screen that would otherwise draw its own header (a [SheetView] mounted
  /// as a page, say) hands its title and actions to that title bar via
  /// [kDetachedChromeBranch] instead of drawing a second header inside the
  /// frame. The right sidebar has no title bar, so it leaves this false and its
  /// panels keep their own headers.
  final bool hasChrome;

  const DetachedShellHost({
    super.key,
    this.hasChrome = false,
    required super.child,
  });

  static DetachedShellHost? _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DetachedShellHost>();

  static bool of(BuildContext context) => _of(context) != null;

  /// True when the nearest detached host draws its own header chrome.
  static bool drawsChrome(BuildContext context) =>
      _of(context)?.hasChrome ?? false;

  @override
  bool updateShouldNotify(DetachedShellHost oldWidget) =>
      oldWidget.hasChrome != hasChrome;
}

/// Pseudo-branch under which a screen hosted by a chrome-drawing
/// [DetachedShellHost] publishes its header, so the host's title bar can render
/// it. Negative so it can never collide with a real shell branch index.
const int kDetachedChromeBranch = -1;

/// Mix into a shell screen's [ConsumerState] to publish a header into
/// [shellHeaderProvider]. Implement [headerBranchIndex] and [buildShellHeader],
/// and call [refreshShellHeader] whenever local state affecting the header
/// changes (typically alongside `setState`).
mixin ShellHeaderMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  int get headerBranchIndex;

  ShellHeaderConfig buildShellHeader();

  /// Set false by a screen mounted somewhere that has no shell header to fill
  /// — the desktop right sidebar hosts a second [ToolsScreen] instance, and a
  /// duplicate claim on the same branch would fight the routed one.
  bool get publishesShellHeader => true;

  // Cached so it can be used safely in [dispose], where reading `ref` is unsafe.
  ShellHeaderRegistry? _registry;

  @override
  void initState() {
    super.initState();
    if (!publishesShellHeader) return;
    _registry = ref.read(shellHeaderProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _registry?.publish(this, headerBranchIndex, buildShellHeader());
    });
  }

  /// Re-publishes the current header config. Safe to call from event handlers;
  /// no-ops before the first post-frame publish if the widget is unmounted.
  void refreshShellHeader() {
    if (!mounted) return;
    _registry?.publish(this, headerBranchIndex, buildShellHeader());
  }

  @override
  void dispose() {
    // Deferred: removing during widget-tree finalization would modify the
    // provider mid-build, which Riverpod forbids.
    final registry = _registry;
    WidgetsBinding.instance.addPostFrameCallback((_) => registry?.remove(this));
    super.dispose();
  }
}
