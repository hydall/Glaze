import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../../core/platform/desktop_window.dart';

typedef AppWindowState = ({bool focused, bool maximized});

/// Focus and maximize state of the app's OS window, followed through
/// window_manager. On a platform without a desktop window it stays focused and
/// never maximized.
class AppWindowStateNotifier extends Notifier<AppWindowState>
    with WindowListener {
  @override
  AppWindowState build() {
    if (!isDesktopAppWindow) return (focused: true, maximized: false);
    windowManager.addListener(this);
    ref.onDispose(() => windowManager.removeListener(this));
    unawaited(_sync());
    return (focused: true, maximized: false);
  }

  /// Reads the real state once: the window may already be maximized (restored
  /// geometry) or unfocused by the time anything listens.
  Future<void> _sync() async {
    try {
      final focused = await windowManager.isFocused();
      final maximized = await windowManager.isMaximized();
      if (ref.mounted) state = (focused: focused, maximized: maximized);
    } catch (_) {
      // No window_manager plugin behind the channel (tests): keep the defaults.
    }
  }

  @override
  void onWindowFocus() => state = (focused: true, maximized: state.maximized);

  @override
  void onWindowBlur() => state = (focused: false, maximized: state.maximized);

  @override
  void onWindowMaximize() => state = (focused: state.focused, maximized: true);

  @override
  void onWindowUnmaximize() =>
      state = (focused: state.focused, maximized: false);
}

final appWindowStateProvider =
    NotifierProvider<AppWindowStateNotifier, AppWindowState>(
      AppWindowStateNotifier.new,
    );
