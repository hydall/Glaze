import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Screens that want the shell's bottom nav bar hidden while they are on
/// screen — full-height editors (the preset block editor) that need every pixel
/// and would otherwise have their content run under the bar.
///
/// A registry rather than a bool so overlapping claims cannot un-hide each
/// other: the bar is hidden while at least one claim is live. Mirrors
/// [shellHeaderProvider], and like it is mutated only outside the build phase.
class NavBarSuppressionRegistry extends Notifier<Set<Object>> {
  bool _disposed = false;

  @override
  Set<Object> build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const {};
  }

  void suppress(Object key) {
    if (_disposed || state.contains(key)) return;
    state = {...state, key};
  }

  void release(Object key) {
    if (_disposed || !state.contains(key)) return;
    state = {
      for (final entry in state)
        if (entry != key) entry,
    };
  }
}

final navBarSuppressionProvider =
    NotifierProvider<NavBarSuppressionRegistry, Set<Object>>(
      NavBarSuppressionRegistry.new,
    );

/// Hides the shell's bottom nav bar for as long as this widget is mounted.
class NavBarSuppressor extends ConsumerStatefulWidget {
  final Widget child;

  const NavBarSuppressor({super.key, required this.child});

  @override
  ConsumerState<NavBarSuppressor> createState() => _NavBarSuppressorState();
}

class _NavBarSuppressorState extends ConsumerState<NavBarSuppressor> {
  final Object _claim = Object();

  /// Captured up front: by `dispose` this state is unmounting and `ref.read`
  /// can no longer be relied on, but the registry outlives the widget, so the
  /// claim is released through the notifier directly.
  NavBarSuppressionRegistry? _registry;

  @override
  void initState() {
    super.initState();
    // Deferred: initState runs during the build phase, where mutating a
    // provider is forbidden.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Two statements, not a cascade: `a = b..m()` binds the cascade to the
      // assignment, whose static type is the nullable field.
      final registry = ref.read(navBarSuppressionProvider.notifier);
      _registry = registry;
      registry.suppress(_claim);
    });
  }

  @override
  void dispose() {
    final registry = _registry;
    if (registry != null) {
      // Unmount runs inside BuildOwner.finalizeTree, where Riverpod forbids
      // synchronous notifications. Release after the widget lifecycle ends.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        registry.release(_claim);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
