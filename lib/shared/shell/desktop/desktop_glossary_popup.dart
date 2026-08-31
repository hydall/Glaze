import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/state/shared_prefs_provider.dart';
import '../../../features/glossary/glossary_sheet.dart';
import '../../theme/app_colors.dart';
import '../../widgets/glass_surface.dart';

final glossaryPopupVisibleProvider = StateProvider<bool>((ref) => false);

const _prefsKeyX = 'gz_glossary_popup_x';
const _prefsKeyY = 'gz_glossary_popup_y';

/// Free-floating glossary window pinned to a corner of the desktop layout.
///
/// The hosted [GlossarySheet] brings its own header — localized title and the
/// back arrow that walks category → article — so this frame only adds the drag
/// strip and the close button, the way Vue's `.desktop-glossary-popup` did.
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
  bool _restored = false;

  double _height(Size viewport) =>
      (viewport.height * 0.6).clamp(0.0, viewport.height * 0.8);

  /// Clamps into the viewport, tolerating a window smaller than the popup:
  /// `clamp` throws when the upper bound falls below the lower one, which a
  /// short desktop window (height < popup height) would otherwise trigger.
  Offset _clamp(Offset value, Size viewport, Size size) {
    final maxX = (viewport.width - size.width).clamp(0.0, double.infinity);
    final maxY = (viewport.height - size.height).clamp(0.0, double.infinity);
    return Offset(value.dx.clamp(0.0, maxX), value.dy.clamp(0.0, maxY));
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

  @override
  Widget build(BuildContext context) {
    final visible = ref.watch(glossaryPopupVisibleProvider);
    final viewport = MediaQuery.sizeOf(context);
    final size = Size(_width.clamp(0.0, viewport.width), _height(viewport));

    if (!visible) return const SizedBox.shrink();
    if (!_restored) _restorePosition();

    // Bottom-left by default, like the Vue popup.
    final position = _clamp(
      _position ?? Offset(_margin, viewport.height - size.height - _margin),
      viewport,
      size,
    );

    return Positioned(
      left: position.dx,
      top: position.dy,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: GlassSurface(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.cs.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 32,
              spreadRadius: 2,
            ),
          ],
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Column(
              children: [
                _DragStrip(
                  onDrag: (delta) {
                    setState(
                      () =>
                          _position = _clamp(position + delta, viewport, size),
                    );
                  },
                  onDragEnd: () {
                    final settled = _position;
                    if (settled != null) _persistPosition(settled);
                  },
                  onClose: () =>
                      ref.read(glossaryPopupVisibleProvider.notifier).state =
                          false,
                ),
                const Expanded(child: GlossarySheet(startExpanded: true)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DragStrip extends StatelessWidget {
  final void Function(Offset delta) onDrag;
  final VoidCallback onDragEnd;
  final VoidCallback onClose;

  const _DragStrip({
    required this.onDrag,
    required this.onDragEnd,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => onDrag(d.delta),
        onPanEnd: (_) => onDragEnd(),
        child: Container(
          height: 32,
          color: context.cs.onSurface.withValues(alpha: 0.04),
          child: Row(
            children: [
              const SizedBox(width: 12),
              Icon(
                Icons.drag_indicator_rounded,
                size: 16,
                color: context.cs.onSurfaceVariant,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 16),
                tooltip: 'btn_close'.tr(),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: onClose,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}
