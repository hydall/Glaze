import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_window_state_provider.dart';

/// The main window's own surface: the three columns under the floating
/// windows.
const Object kDesktopMainSurface = 'main';

/// The glossary window a help tip opens.
const Object kDesktopGlossarySurface = 'glossary';

/// The surface of the floating window [windowId].
Object desktopWindowSurface(int windowId) => 'window:$windowId';

/// Which window the user is working in — the main window or one of the windows
/// drawn over it — most recently used first.
///
/// The first entry is the active one. The main window sits at the bottom and
/// is never released, so closing the active window hands the active state
/// back to whichever was used before it, the way an OS window manager does.
class DesktopActiveSurfaceNotifier extends Notifier<List<Object>> {
  @override
  List<Object> build() => const [kDesktopMainSurface];

  /// Makes [surface] the active one.
  void activate(Object surface) {
    if (!ref.mounted || state.first == surface) return;
    state = [surface, ...state.where((s) => s != surface)];
  }

  /// Drops [surface] — a window that closed or was minimized.
  void release(Object surface) {
    if (!ref.mounted || surface == kDesktopMainSurface) return;
    if (!state.contains(surface)) return;
    state = state.where((s) => s != surface).toList();
  }
}

final desktopActiveSurfaceProvider =
    NotifierProvider<DesktopActiveSurfaceNotifier, List<Object>>(
      DesktopActiveSurfaceNotifier.new,
    );

/// Whether [surface] should draw as the active window: it is the most recently
/// used one and the app's own OS window has focus. While the user is in
/// another app every title bar dims, as native ones do.
final desktopSurfaceActiveProvider = Provider.autoDispose.family<bool, Object>((
  ref,
  surface,
) {
  final focused = ref.watch(appWindowStateProvider.select((s) => s.focused));
  final mostRecent = ref.watch(
    desktopActiveSurfaceProvider.select((s) => s.first == surface),
  );
  return focused && mostRecent;
});
