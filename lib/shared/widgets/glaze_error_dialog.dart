import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/error_format.dart';
import '../theme/theme_font_provider.dart';
import 'glass_surface.dart';

class GlazeErrorDialog {
  static void show(BuildContext context, Object error, {String prefix = ''}) {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, _, _) =>
          _ErrorDialogContent(message: '$prefix${formatError(error)}'),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );

        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(
              begin: 0.96,
              end: 1,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
}

class _ErrorDialogContent extends ConsumerStatefulWidget {
  final String message;

  const _ErrorDialogContent({required this.message});

  @override
  ConsumerState<_ErrorDialogContent> createState() =>
      _ErrorDialogContentState();
}

class _ErrorDialogContentState extends ConsumerState<_ErrorDialogContent> {
  bool _copied = false;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.message));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final uiFont = ref.watch(uiFontFamilyProvider).value;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FFFFFF)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header ─────────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: cs.primary,
                      size: 17,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'error_oops'.tr().toUpperCase(),
                        style: TextStyle(
                          fontFamily: uiFont,
                          color: cs.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: cs.onSurfaceVariant,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
              ),
              const Divider(height: 1, thickness: 1, color: Color(0x22FFFFFF)),
              // ── Scrollable error text ───────────────────────────────────────
              Flexible(
                child: Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(14),
                    child: SelectableText(
                      widget.message,
                      style: TextStyle(
                        fontFamily: uiFont,
                        color: const Color(0xFFCF6679),
                        fontSize: 12.5,
                        height: 1.55,
                      ),
                    ),
                  ),
                ),
              ),
              // ── Copy row ───────────────────────────────────────────────────
              const Divider(height: 1, thickness: 1, color: Color(0x22FFFFFF)),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _copy,
                  customBorder: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(16),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _copied ? Icons.check_rounded : Icons.copy_rounded,
                          size: 15,
                          color: _copied ? cs.primary : cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _copied ? 'Copied' : 'Copy',
                          style: TextStyle(
                            fontFamily: uiFont,
                            fontSize: 13,
                            color: _copied ? cs.primary : cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
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
