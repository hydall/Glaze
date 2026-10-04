import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/state/shared_prefs_provider.dart';
import '../../../features/glossary/glossary_sheet.dart';
import '../shell_header_provider.dart';
import 'desktop_active_surface_provider.dart';
import 'desktop_window_chrome.dart';
import 'desktop_window_geometry.dart';

final glossaryPopupVisibleProvider = StateProvider<bool>((ref) => false);

/// Term the window should open on, set by a [HelpTip] tap. Null opens the
/// glossary at its category list.
final glossaryPopupTermProvider = StateProvider<String?>((ref) => null);

/// Opens the floating glossary window, jumped straight to [term] when given.
void openGlossaryPopup(WidgetRef ref, {String? term}) {
  ref.read(glossaryPopupTermProvider.notifier).state = term;
  ref.read(glossaryPopupVisibleProvider.notifier).state = true;
}

const _prefsKeyX = 'gz_glossary_popup_x';
const _prefsKeyY = 'gz_glossary_popup_y';

/// Header pseudo-branch the hosted [GlossarySheet] publishes its title and
/// back button under. Clear of the sheet windows' (-2 to -501) and the
/// floating windows' (-1001 down).
const int _kGlossaryHeaderBranch = -900;

/// Free-floating glossary window pinned to a corner of the desktop layout.
///
/// Drawn with the same frame and title bar as the other desktop windows. The
/// hosted [GlossarySheet] hands its header to that title bar — localized title
/// and the back arrow that walks category → article — instead of drawing a
/// second one inside the frame.
class DesktopGlossaryPopup extends ConsumerStatefulWidget {
  const DesktopGlossaryPopup({super.key});

  @override
  ConsumerState<DesktopGlossaryPopup> createState() =>
      _DesktopGlossaryPopupState();
}

class _DesktopGlossaryPopupState extends ConsumerState<DesktopGlossaryPopup> {
  static const double _width = 380;
  static const double _margin = 20;

  /// Null until the first layout, which pins it to the bottom-left corner.
  Offset? _position;
  Offset _moveStart = Offset.zero;
  bool _restored = false;

  double _height(Size viewport) =>
      (viewport.height * 0.6).clamp(0.0, viewport.height * 0.8);

  /// Clamps into the viewport below its [top] inset (the app's title bar),
  /// tolerating a window smaller than the popup: `clamp` throws when the upper
  /// bound falls below the lower one, which a short desktop window (height <
  /// popup height) would otherwise trigger.
  Offset _clamp(Offset value, Size viewport, Size size, double top) {
    final maxX = (viewport.width - size.width).clamp(0.0, double.infinity);
    final maxY = (viewport.height - size.height).clamp(top, double.infinity);
    return Offset(value.dx.clamp(0.0, maxX), value.dy.clamp(top, maxY));
  }

  Future<void> _restorePosition() async {
    _restored = true;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    if (!mounted) return;
    final x = prefs.getDouble(_prefsKeyX);
    final y = prefs.getDouble(_prefsKeyY);
    if (x == null || y == null) return;
    setState(() => _position = Offset(x, y));
  }

  Future<void> _persistPosition(Offset value) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setDouble(_prefsKeyX, value.dx);
    await prefs.setDouble(_prefsKeyY, value.dy);
  }

  void _close() =>
      ref.read(glossaryPopupVisibleProvider.notifier).state = false;

  @override
  Widget build(BuildContext context) {
    // Opening the glossary makes it the active window; closing it hands that
    // back to whichever window was active before.
    ref.listen(glossaryPopupVisibleProvider, (_, visible) {
      final surfaces = ref.read(desktopActiveSurfaceProvider.notifier);
      if (visible) {
        surfaces.activate(kDesktopGlossarySurface);
      } else {
        surfaces.release(kDesktopGlossarySurface);
      }
    });
    final visible = ref.watch(glossaryPopupVisibleProvider);
    final term = ref.watch(glossaryPopupTermProvider);
    final viewport = MediaQuery.sizeOf(context);
    final top = MediaQuery.paddingOf(context).top;
    final size = Size(_width.clamp(0.0, viewport.width), _height(viewport));

    if (!visible) return const SizedBox.shrink();
    if (!_restored) _restorePosition();

    // Bottom-left by default, like the Vue popup.
    final position = _clamp(
      _position ?? Offset(_margin, viewport.height - size.height - _margin),
      viewport,
      size,
      top,
    );

    return Positioned(
      left: position.dx,
      top: position.dy,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Listener(
          onPointerDown: (_) => ref
              .read(desktopActiveSurfaceProvider.notifier)
              .activate(kDesktopGlossarySurface),
          child: DesktopWindowMoveScope(
            onMoveStart: () => _moveStart = position,
            onMoveUpdate: (delta) => setState(
              () => _position = _clamp(_moveStart + delta, viewport, size, top),
            ),
            onMoveEnd: () {
              final settled = _position;
              if (settled != null) _persistPosition(settled);
            },
            child: _GlossaryWindowFrame(term: term, onClose: _close),
          ),
        ),
      ),
    );
  }
}

class _GlossaryWindowFrame extends ConsumerWidget {
  final String? term;
  final VoidCallback onClose;

  const _GlossaryWindowFrame({required this.term, required this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(
      desktopSurfaceActiveProvider(kDesktopGlossarySurface),
    );
    final header = ref.watch(
      shellHeaderProvider.select(
        (e) => resolveShellHeader(e, _kGlossaryHeaderBranch)?.config,
      ),
    );

    return DesktopWindowFrame(
      active: active,
      titleBar: DesktopWindowMoveArea(
        child: DesktopWindowTitleBar(
          title: header?.title ?? 'menu_glossary'.tr(),
          active: active,
          onBack: header != null && header.showBack ? header.onBack : null,
          onClose: onClose,
        ),
      ),
      child: DetachedShellHost(
        hasChrome: true,
        headerBranch: _kGlossaryHeaderBranch,
        child: GlossarySheet(
          // Keyed by term so re-opening on a different one rebuilds the sheet
          // at that article instead of keeping the old.
          key: ValueKey(term),
          initialTerm: term,
          startExpanded: true,
          onDismiss: onClose,
        ),
      ),
    );
  }
}
