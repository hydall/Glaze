import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';

/// Bottom sheet that lets the user pick the chat layout (`default` / `bubble`)
/// via the visual [LayoutPreviewCard] thumbnails. Shared by the theme editor
/// and the app interface settings.
///
/// [current] is the active layout key; [onSelect] receives the chosen key
/// (`'default'` or `'bubble'`). The sheet is popped before [onSelect] runs.
Future<void> showChatLayoutPicker(
  BuildContext context, {
  required String current,
  required ValueChanged<String> onSelect,
}) {
  void choose(String layout) {
    Navigator.of(context, rootNavigator: true).pop();
    onSelect(layout);
  }

  return GlazeBottomSheet.show<void>(
    context,
    title: 'menu_chat_layout'.tr(),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: LayoutPreviewCard(
              title: 'layout_default'.tr(),
              subtitle: 'layout_default_desc'.tr(),
              isActive: current == 'default',
              onTap: () => choose('default'),
              child: const LayoutMiniPreview(layout: 'default'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: LayoutPreviewCard(
              title: 'layout_bubble'.tr(),
              subtitle: 'layout_bubble_desc'.tr(),
              isActive: current == 'bubble',
              onTap: () => choose('bubble'),
              child: const LayoutMiniPreview(layout: 'bubble'),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Tappable card framing a [LayoutMiniPreview] thumbnail with a title/subtitle.
class LayoutPreviewCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool isActive;
  final VoidCallback onTap;
  final Widget child;

  const LayoutPreviewCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.isActive,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isActive
                ? context.cs.primary.withValues(alpha: 0.16)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isActive
                  ? context.cs.primary.withValues(alpha: 0.45)
                  : Colors.white.withValues(alpha: 0.1),
              width: isActive ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(aspectRatio: 0.88, child: child),
              const SizedBox(height: 10),
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: context.cs.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Schematic thumbnail of a chat layout (`default` = full-width left-aligned
/// log; `bubble` = left/right bubbles).
class LayoutMiniPreview extends StatelessWidget {
  final String layout;

  const LayoutMiniPreview({
    super.key,
    required this.layout,
  });

  @override
  Widget build(BuildContext context) {
    final bubble = layout == 'bubble';
    final surface = context.cs.surfaceContainerHighest.withValues(alpha: 0.55);
    final line = context.cs.outlineVariant.withValues(alpha: 0.8);
    final user = context.cs.primary.withValues(alpha: 0.85);
    final char = context.cs.surface.withValues(alpha: 0.95);

    // Render at a fixed design size (ratio ≈ 0.88) and scale to fit the
    // available box. Keeps the schematic from overflowing when the host card
    // is narrower than the content's intrinsic height (e.g. narrow windows).
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: 140,
        height: 159,
        child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: surface,
        border: Border.all(color: line),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 12,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(height: 12),
          if (!bubble) ...[
            const _MiniHeaderRow(),
            const SizedBox(height: 6),
            const _MiniTextLine(widthFactor: 0.82),
            const SizedBox(height: 4),
            const _MiniTextLine(widthFactor: 0.66),
            const SizedBox(height: 10),
            const _MiniHeaderRow(isUser: true),
            const SizedBox(height: 6),
            const _MiniTextLine(widthFactor: 0.76),
            const SizedBox(height: 4),
            const _MiniTextLine(widthFactor: 0.54),
          ] else ...[
            Align(
              alignment: Alignment.centerLeft,
              child: _MiniBubble(
                color: char,
                widthFactor: 0.7,
                alignRight: false,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: _MiniBubble(
                color: user,
                widthFactor: 0.64,
                alignRight: true,
              ),
            ),
          ],
        ],
      ),
        ),
      ),
    );
  }
}

class _MiniHeaderRow extends StatelessWidget {
  final bool isUser;

  const _MiniHeaderRow({this.isUser = false});

  @override
  Widget build(BuildContext context) {
    // Default layout is full-width and left-aligned for both author and user;
    // the avatar always precedes the name. Only the avatar color differs.
    return Row(
      children: [
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isUser
                ? context.cs.primary.withValues(alpha: 0.75)
                : Colors.white.withValues(alpha: 0.18),
          ),
        ),
        const SizedBox(width: 6),
        Container(
          width: 40,
          height: 7,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: Colors.white.withValues(alpha: 0.16),
          ),
        ),
      ],
    );
  }
}

class _MiniTextLine extends StatelessWidget {
  final double widthFactor;

  const _MiniTextLine({
    required this.widthFactor,
  });

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 7,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: Colors.white.withValues(alpha: 0.13),
        ),
      ),
    );
  }
}

class _MiniBubble extends StatelessWidget {
  final Color color;
  final double widthFactor;
  final bool alignRight;

  const _MiniBubble({
    required this.color,
    required this.widthFactor,
    required this.alignRight,
  });

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(alignRight ? 12 : 4),
            topRight: Radius.circular(alignRight ? 4 : 12),
            bottomLeft: const Radius.circular(12),
            bottomRight: const Radius.circular(12),
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          children: [
            Container(
              height: 6,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: alignRight
                    ? Colors.white.withValues(alpha: 0.55)
                    : context.cs.onSurface.withValues(alpha: 0.15),
              ),
            ),
            const SizedBox(height: 4),
            FractionallySizedBox(
              widthFactor: 0.72,
              child: Container(
                height: 6,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: alignRight
                      ? Colors.white.withValues(alpha: 0.4)
                      : context.cs.onSurface.withValues(alpha: 0.1),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
