import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/error_format.dart';
import '../../features/settings/app_settings_provider.dart';

final toastOverlayKey = GlobalKey<OverlayState>();

enum ToastPosition { top, bottom }

class GlazeToast {
  static _ActiveToast? _current;

  static OverlayState? _resolveOverlay(BuildContext? context) {
    final top = toastOverlayKey.currentState;
    if (top != null) return top;
    if (context != null) {
      return Overlay.of(context, rootOverlay: true);
    }
    return null;
  }

  static void show(
    BuildContext context,
    String text, {
    int duration = 2500,
    ToastPosition position = ToastPosition.bottom,
    bool isError = false,
    bool showCopyButton = false,
  }) {
    final overlay = _resolveOverlay(context);
    if (overlay != null) {
      _showOnOverlay(
        overlay,
        text,
        duration: duration,
        position: position,
        isError: isError,
        showCopyButton: showCopyButton,
      );
    }
  }

  static void _showOnOverlay(
    OverlayState overlay,
    String text, {
    int duration = 2500,
    ToastPosition position = ToastPosition.bottom,
    bool isError = false,
    bool showCopyButton = false,
  }) {
    _current?.cancel();

    final key = GlobalKey<_ToastAnimatorState>();
    late final OverlayEntry entry;

    entry = OverlayEntry(
      builder: (_) => _ToastAnimator(
        key: key,
        text: text,
        position: position,
        isError: isError,
        showCopyButton: showCopyButton,
        onRemove: () {
          entry.remove();
          if (_current?.entry == entry) _current = null;
        },
      ),
    );

    overlay.insert(entry);

    final timer = Timer(
      Duration(milliseconds: duration),
      () => key.currentState?.dismiss(),
    );

    _current = _ActiveToast(entry: entry, key: key, timer: timer);
  }

  static void hide() => _current?.cancel();

  static void showWithoutContext(
    String text, {
    int duration = 2500,
    ToastPosition position = ToastPosition.bottom,
    bool isError = false,
  }) {
    final overlay = _resolveOverlay(null);
    if (overlay != null) {
      _showOnOverlay(
        overlay,
        text,
        duration: duration,
        position: position,
        isError: isError,
      );
    }
  }

  static void error(BuildContext context, String prefix, Object err) {
    final text = '$prefix${formatError(err)}';
    show(
      context,
      text,
      duration: 4000,
      position: ToastPosition.top,
      isError: true,
    );
  }

  static void errorWithCopy(BuildContext context, String prefix, Object err) {
    final text = '$prefix${formatError(err)}';
    show(
      context,
      text,
      duration: 8000,
      position: ToastPosition.top,
      isError: true,
      showCopyButton: true,
    );
  }
}

// ── Internal state tracker ────────────────────────────────────────────────────

class _ActiveToast {
  final OverlayEntry entry;
  final GlobalKey<_ToastAnimatorState> key;
  final Timer timer;

  _ActiveToast({required this.entry, required this.key, required this.timer});

  void cancel() {
    timer.cancel();
    key.currentState?.dismiss();
  }
}

// ── Animated toast widget ─────────────────────────────────────────────────────

class _ToastAnimator extends StatefulWidget {
  final String text;
  final ToastPosition position;
  final bool isError;
  final bool showCopyButton;
  final VoidCallback onRemove;

  const _ToastAnimator({
    super.key,
    required this.text,
    required this.position,
    this.isError = false,
    this.showCopyButton = false,
    required this.onRemove,
  });

  @override
  State<_ToastAnimator> createState() => _ToastAnimatorState();
}

class _ToastAnimatorState extends State<_ToastAnimator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;
  late final Animation<double> _translateY;

  static const _enterCurve = Cubic(0.34, 1.56, 0.64, 1);
  static const _enterDuration = Duration(milliseconds: 300);
  static const _leaveDuration = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _enterDuration);

    _opacity = Tween(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));

    _scale = Tween(
      begin: 0.85,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: _enterCurve));

    // Bottom toasts enter from below, top toasts enter from above
    final enterOffset = widget.position == ToastPosition.bottom ? 20.0 : -20.0;
    _translateY = Tween(
      begin: enterOffset,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: _enterCurve));

    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> dismiss() async {
    if (!mounted) return;
    _ctrl.duration = _leaveDuration;
    await _ctrl.animateBack(0.0, curve: Curves.easeIn);
    if (mounted) widget.onRemove();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final isBottom = widget.position == ToastPosition.bottom;

    // bottom: above nav bar (~80px) + margin; top: below status bar + header
    final double positionValue = isBottom
        ? mq.padding.bottom + 80 + 24
        : mq.padding.top + 56 + 16;

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        return Positioned(
          left: 0,
          right: 0,
          bottom: isBottom ? positionValue : null,
          top: isBottom ? null : positionValue,
          child: IgnorePointer(
            ignoring: false,
            child: Center(
              child: Transform.translate(
                offset: Offset(0, _translateY.value),
                child: Transform.scale(
                  scale: _scale.value,
                  child: Opacity(
                    opacity: _opacity.value,
                    child: _ToastChip(
                      text: widget.text,
                      onTap: dismiss,
                      isError: widget.isError,
                      showCopyButton: widget.showCopyButton,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── Visual chip ───────────────────────────────────────────────────────────────

class _ToastChip extends ConsumerStatefulWidget {
  final String text;
  final VoidCallback onTap;
  final bool isError;
  final bool showCopyButton;

  const _ToastChip({
    required this.text,
    required this.onTap,
    this.isError = false,
    this.showCopyButton = false,
  });

  @override
  ConsumerState<_ToastChip> createState() => _ToastChipState();
}

class _ToastChipState extends ConsumerState<_ToastChip> {
  bool _copied = false;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.text));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        onTap: widget.showCopyButton ? null : widget.onTap,
        onLongPress: widget.showCopyButton
            ? null
            : () {
                Clipboard.setData(ClipboardData(text: widget.text));
              },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: (ref.watch(appSettingsProvider).value?.batterySaver ?? false)
              ? _toastContent(opaque: true)
              : BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: _toastContent(),
                ),
        ),
      ),
    );
  }

  Widget _toastContent({bool opaque = false}) {
    final bgColor = opaque
        ? (widget.isError ? const Color(0xFF5C1A1A) : const Color(0xFF1E1E1E))
        : (widget.isError ? const Color(0xEB5C1A1A) : const Color(0xEB1E1E1E));
    return Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width - 48,
      ),
      padding: EdgeInsets.fromLTRB(20, 10, widget.showCopyButton ? 8 : 20, 10),
      decoration: BoxDecoration(
        color: bgColor,
        border: widget.isError
            ? Border.all(color: const Color(0x80FF4444), width: 1)
            : null,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x401A1A1A),
            blurRadius: 20,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              widget.text,
              textAlign: TextAlign.left,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Colors.white,
                height: 1.3,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          if (widget.showCopyButton) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _copy,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _copied ? 'Copied' : 'Copy',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
