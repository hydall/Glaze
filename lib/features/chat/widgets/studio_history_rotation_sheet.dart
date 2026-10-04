import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';

enum StudioHistoryRotationAction { ok, memory }

Future<StudioHistoryRotationAction?> showStudioHistoryRotationSheet(
  BuildContext context, {
  required int droppedMessageCount,
}) => GlazeBottomSheet.show<StudioHistoryRotationAction>(
  context,
  locked: true,
  isDismissible: false,
  child: _StudioHistoryRotationContent(
    droppedMessageCount: droppedMessageCount,
  ),
);

class _StudioHistoryRotationContent extends StatefulWidget {
  final int droppedMessageCount;

  const _StudioHistoryRotationContent({required this.droppedMessageCount});

  @override
  State<_StudioHistoryRotationContent> createState() =>
      _StudioHistoryRotationContentState();
}

class _StudioHistoryRotationContentState
    extends State<_StudioHistoryRotationContent> {
  static const _lockSeconds = 5;
  int _remaining = _lockSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _remaining--;
        if (_remaining <= 0) timer.cancel();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final okEnabled = _remaining <= 0;
    return PopScope(
      canPop: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.compress_rounded, size: 52, color: context.cs.primary),
            const SizedBox(height: 14),
            Text(
              'studio_history_rotated_title'.tr(),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'studio_history_rotated_desc'.tr(
                args: ['${widget.droppedMessageCount}'],
              ),
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: context.cs.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _ActionTile(
                    icon: Icons.psychology_alt_outlined,
                    label: 'studio_history_open_memory'.tr(),
                    onTap: () => Navigator.of(
                      context,
                      rootNavigator: true,
                    ).pop(StudioHistoryRotationAction.memory),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionTile(
                    icon: Icons.check_rounded,
                    label: okEnabled
                        ? 'btn_ok'.tr()
                        : '${'btn_ok'.tr()} ($_remaining)',
                    onTap: okEnabled
                        ? () => Navigator.of(
                            context,
                            rootNavigator: true,
                          ).pop(StudioHistoryRotationAction.ok)
                        : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ActionTile({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = enabled ? context.cs.primary : context.cs.onSurfaceVariant;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: GlassSurface(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.cs.outlineVariant),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(fontWeight: FontWeight.w600, color: color),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
