import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/models/character.dart';
import '../../../core/models/character_folder.dart';
import '../../../core/utils/platform_paths.dart';
import '../../../shared/theme/app_colors.dart';

/// Folder cover card for the My Characters folders section. Mirrors the Picks
/// folder card visuals, but builds its collage from local character avatars.
class CharacterFolderCard extends StatefulWidget {
  final CharacterFolder folder;
  final List<Character> members;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const CharacterFolderCard({
    super.key,
    required this.folder,
    required this.members,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<CharacterFolderCard> createState() => _CharacterFolderCardState();
}

class _CharacterFolderCardState extends State<CharacterFolderCard> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = _pressed ? 0.96 : (_hovered ? 1.01 : 1.0);
    final dy = _hovered && !_pressed ? -4.0 : 0.0;
    final shadowColor = Colors.black.withValues(alpha: _hovered ? 0.3 : 0.1);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutBack,
          transform: Matrix4.identity()
            ..translateByDouble(0.0, dy, 0.0, 1.0)
            ..scaleByDouble(scale, scale, 1.0, 1.0),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: shadowColor,
                blurRadius: _hovered ? 24 : 6,
                offset: Offset(0, _hovered ? 12 : 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedScale(
                  scale: _hovered ? 1.05 : 1.0,
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOut,
                  child: _buildBackground(context),
                ),
                const Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 150,
                  child: _BottomGradient(),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _info(context),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _info(BuildContext context) {
    final count = widget.members.length;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 3),
                child: Icon(
                  Icons.folder_rounded,
                  size: 14,
                  color: Colors.white,
                  shadows: [Shadow(blurRadius: 2, color: Colors.black54)],
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.folder.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: Colors.white,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '$count ${'count_characters'.plural(count)}',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.75),
              shadows: const [Shadow(blurRadius: 4, color: Colors.black87)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground(BuildContext context) {
    final previews = widget.members
        .where((c) => (c.avatarPath?.isNotEmpty ?? false))
        .take(3)
        .toList();

    if (previews.isEmpty) return _gradient(context);
    if (previews.length == 1) return _avatar(context, previews[0]);

    if (previews.length == 2) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _avatar(context, previews[0])),
          const SizedBox(width: 2),
          Expanded(child: _avatar(context, previews[1])),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 2, child: _avatar(context, previews[0])),
        const SizedBox(width: 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _avatar(context, previews[1])),
              const SizedBox(height: 2),
              Expanded(child: _avatar(context, previews[2])),
            ],
          ),
        ),
      ],
    );
  }

  Widget _avatar(BuildContext context, Character c) {
    // Collage thumbnails are tiny; use the 512px thumbnail (fallback to the
    // source avatar) so the grid doesn't decode full-res PNGs while scrolling.
    final resolved = resolveGlazeThumbnailPath(c.avatarPath);
    if (resolved == null) return _gradient(context);
    return Image.file(
      File(resolved),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => _gradient(context),
    );
  }

  Widget _gradient(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            context.cs.primary.withValues(alpha: 0.1),
            context.cs.surfaceContainerHighest,
          ],
        ),
      ),
    );
  }
}

/// "+ New folder" tile shown as the first item in the folders grid.
class NewFolderCard extends StatelessWidget {
  final VoidCallback onTap;
  const NewFolderCard({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: context.cs.primary.withValues(alpha: 0.05),
          border: Border.all(
            color: context.cs.primary.withValues(alpha: 0.35),
            width: 1.5,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.create_new_folder_rounded,
                  size: 32, color: context.cs.primary),
              const SizedBox(height: 8),
              Text(
                'folder_new'.tr(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
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

class _BottomGradient extends StatelessWidget {
  const _BottomGradient();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xF2000000), Color(0x99000000), Colors.transparent],
          stops: [0.0, 0.5, 1.0],
        ),
      ),
    );
  }
}
