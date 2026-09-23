import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';

/// The glass box every preset-editor section lives in. One shell so the
/// dashboard, the agent list and the block list read as the same material.
class PresetCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets margin;

  const PresetCard({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.fromLTRB(16, 16, 16, 0),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: GlassSurface(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.cs.outline),
        // The dashboard's cover band bleeds to the card's edges, and a border
        // painted behind the child is simply covered by it — the frame would
        // break wherever the art sits. Sections whose child is padded look the
        // same either way, so this holds for every card.
        borderOnTop: true,
        child: child,
      ),
    );
  }
}

/// The preset editor's dashboard: the preset identity (cover art, name,
/// subtitle, overflow menu), a row of utility buttons and stat badges, and
/// optionally the preset's block list with an "Add Block" row.
///
/// Shared by the plain preset editor and the agentic (Studio) preset editor.
/// The agentic one keeps its blocks in a card of their own, so [blockList] and
/// [onAddBlock] are optional.
class PresetDashboardCard extends StatelessWidget {
  /// Cover art. Rendered as a full-width band anchored to the top of the card
  /// that fades out into the glass — the legacy Vue editor's treatment — rather
  /// than as a thumbnail beside the title.
  final ImageProvider? coverImage;
  final VoidCallback? onCoverTap;

  /// Shown left of the title when there is no cover (the agentic editor's
  /// robot glyph).
  final Widget? leading;

  final String title;

  /// Second line under the title (e.g. `by <author>`). Null hides the line.
  final String? subtitle;
  final VoidCallback? onTitleTap;
  final VoidCallback onMenuTap;

  /// Utility buttons pinned to the left of the utils row.
  final List<Widget> utilsLeading;

  /// Stat badges pinned to the right of the utils row.
  final List<Widget> utilsTrailing;

  /// Optional strip between the utils row and the block list.
  /// Supplies its own padding.
  final Widget? belowUtils;

  final Widget? blockList;

  /// Null hides the "Add Block" row entirely.
  final VoidCallback? onAddBlock;

  /// Mirrors the `addBlockAtTop` app setting: puts the add row above the list.
  final bool addBlockAtTop;

  /// Null falls back to the shared `add_block` string.
  final String? addBlockLabel;

  const PresetDashboardCard({
    super.key,
    this.coverImage,
    this.onCoverTap,
    this.leading,
    required this.title,
    this.subtitle,
    this.onTitleTap,
    required this.onMenuTap,
    this.utilsLeading = const [],
    this.utilsTrailing = const [],
    this.belowUtils,
    this.blockList,
    this.onAddBlock,
    this.addBlockAtTop = false,
    this.addBlockLabel,
  });

  /// Height of the cover band. The header and the utils row both sit inside it,
  /// and the art has faded out by the time the block list starts.
  static const double _coverHeight = 200;

  @override
  Widget build(BuildContext context) {
    final cover = coverImage;
    final onCover = cover != null;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header: leading art + name/subtitle + three-dot menu
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!onCover && leading != null) ...[
                leading!,
                const SizedBox(width: 12),
              ],
              Expanded(
                child: GestureDetector(
                  onTap: onTitleTap,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: onCover
                                ? Colors.white
                                : context.cs.onSurface,
                            shadows: onCover
                                ? const [
                                    Shadow(
                                      color: Color(0x80000000),
                                      blurRadius: 4,
                                      offset: Offset(0, 1),
                                    ),
                                  ]
                                : null,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: onCover
                                  ? Colors.white.withValues(alpha: 0.7)
                                  : context.cs.primary.withValues(alpha: 0.8),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              PresetDotsButton(onTap: onMenuTap, onCover: onCover),
            ],
          ),
        ),
        // Utils row: buttons | spacer | stat badges
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Row(
            children: [...utilsLeading, const Spacer(), ...utilsTrailing],
          ),
        ),
        ?belowUtils,
        if (blockList == null && onAddBlock == null)
          // Identity-only card (the agentic editor keeps its blocks in a box of
          // their own): the utils row still needs a bottom margin.
          const SizedBox(height: 16)
        else ...[
          const SizedBox(height: 12),
          if (addBlockAtTop && onAddBlock != null)
            PresetAddBlockRow(
              onTap: onAddBlock!,
              atTop: true,
              label: addBlockLabel,
            ),
          ?blockList,
          if (!addBlockAtTop && onAddBlock != null)
            PresetAddBlockRow(onTap: onAddBlock!, label: addBlockLabel),
        ],
      ],
    );

    return PresetCard(
      child: Stack(
        children: [
          if (cover != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: _coverHeight,
              child: GestureDetector(
                onTap: onCoverTap,
                child: _CoverBand(image: cover),
              ),
            ),
          content,
        ],
      ),
    );
  }
}

// ─── _CoverBand ───────────────────────────────────────────────────────────────

/// Full-width cover art anchored to the top of the dashboard, darkened for
/// legibility and faded out at the bottom so it dissolves into the card instead
/// of ending on a hard edge.
class _CoverBand extends StatelessWidget {
  final ImageProvider image;

  const _CoverBand({required this.image});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Colors.white, Colors.transparent],
          stops: [0.0, 0.55, 1.0],
        ).createShader(rect),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image(
              image: image,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              // A missing/corrupt file falls back to the plain glass rather
              // than Flutter's error box.
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xD9000000),
                    Color(0x8C000000),
                    Color(0x00000000),
                  ],
                  stops: [0.0, 0.4, 1.0],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── PresetAddBlockRow ────────────────────────────────────────────────────────

class PresetAddBlockRow extends StatelessWidget {
  final VoidCallback onTap;

  /// When true the row sits above the block list: drop the bottom-rounded
  /// corners and use a bottom divider instead of a top one.
  final bool atTop;

  /// Null falls back to the shared `add_block` string.
  final String? label;

  const PresetAddBlockRow({
    super.key,
    required this.onTap,
    this.atTop = false,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final radius = atTop
        ? BorderRadius.zero
        : const BorderRadius.only(
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(14),
          );
    return Material(
      color: Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              top: atTop
                  ? BorderSide.none
                  : const BorderSide(color: Color(0x33808080), width: 1),
              bottom: atTop
                  ? const BorderSide(color: Color(0x33808080), width: 1)
                  : BorderSide.none,
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 30), // align with drag handle column
              Icon(Icons.add, size: 16, color: context.cs.primary),
              const SizedBox(width: 8),
              Text(
                label ?? 'add_block'.tr(),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: context.cs.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── PresetDotsButton ─────────────────────────────────────────────────────────

class PresetDotsButton extends StatelessWidget {
  final VoidCallback onTap;

  /// Over cover art the accent-tinted circle disappears, so it switches to the
  /// frosted white treatment the legacy editor used.
  final bool onCover;

  const PresetDotsButton({
    super.key,
    required this.onTap,
    this.onCover = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onCover
          ? Colors.white.withValues(alpha: 0.2)
          : context.cs.primary.withValues(alpha: 0.1),
      shape: onCover
          ? CircleBorder(
              side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            )
          : const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            Icons.more_vert,
            size: 20,
            color: onCover
                ? Colors.white.withValues(alpha: 0.9)
                : context.cs.primary.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}

// ─── PresetUtilButton ─────────────────────────────────────────────────────────

/// Round utility button in the dashboard's utils row, with an optional red
/// count bubble (regex scripts on a plain preset, enabled agents on an agentic
/// one).
class PresetUtilButton extends StatelessWidget {
  final IconData icon;
  final int count;
  final VoidCallback onTap;
  final bool onCover;

  const PresetUtilButton({
    super.key,
    required this.icon,
    required this.count,
    required this.onTap,
    this.onCover = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: onCover
                  ? Colors.white.withValues(alpha: 0.2)
                  : context.cs.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: onCover
                  ? Border.all(color: Colors.white.withValues(alpha: 0.1))
                  : null,
            ),
            child: Icon(
              icon,
              size: 14,
              color: onCover
                  ? Colors.white.withValues(alpha: 0.9)
                  : context.cs.primary.withValues(alpha: 0.7),
            ),
          ),
          if (count > 0)
            Positioned(
              top: -4,
              right: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                height: 12,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF4444),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: context.cs.surface, width: 1),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── PresetStatBadge ──────────────────────────────────────────────────────────

/// Pill badge in the dashboard's utils row (token estimate, requests/turn,
/// agent count…).
class PresetStatBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool onCover;

  const PresetStatBadge({
    super.key,
    required this.icon,
    required this.label,
    this.onCover = false,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = onCover
        ? Colors.white.withValues(alpha: 0.9)
        : context.cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: onCover
            ? Colors.white.withValues(alpha: 0.2)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
        border: onCover
            ? Border.all(color: Colors.white.withValues(alpha: 0.1))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}
