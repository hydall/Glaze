import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/models/character.dart';

import '../../../core/state/character_provider.dart' show avatarVersionProvider;
import '../../../core/utils/platform_paths.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/theme_preset.dart';
import '../../../shared/theme/theme_provider.dart';

class ChatHeader extends ConsumerWidget {
  final Character character;
  final String sessionName;
  final int currentSessionIndex;

  /// Tapping the name / session line opens the character card.
  final VoidCallback? onTapInfo;

  /// Tapping the avatar opens it in the full-screen image viewer. Left null
  /// when the character has no avatar image (only the initial is shown).
  final VoidCallback? onTapAvatar;

  /// One slim row — a small avatar, then the name and the session side by
  /// side — that fits the app's desktop title bar; it also leaves the rest of
  /// the bar free to drag the window by.
  final bool compact;

  /// Sits right after the name / session text (the desktop search toggle).
  final Widget? trailing;

  const ChatHeader({
    super.key,
    required this.character,
    required this.sessionName,
    this.currentSessionIndex = 0,
    this.onTapInfo,
    this.onTapAvatar,
    this.compact = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(avatarVersionProvider);
    final preset = ref.watch(themeProvider.select((s) => s.activePreset));
    final scale = preset.uiFontSize is num
        ? preset.uiFontSizeValue / 15.0
        : 1.0;
    final letterSpacing = preset.uiLetterSpacing;
    final textColor = preset.uiTextParsed ?? context.cs.onSurface;
    final secondaryColor =
        preset.uiTextGrayParsed ?? context.cs.onSurfaceVariant;

    Color avatarColor = context.cs.primary;
    if (character.color != null && character.color!.isNotEmpty) {
      try {
        final String c = character.color!.replaceFirst('#', '');
        avatarColor = Color(int.parse('FF$c', radix: 16));
      } catch (_) {}
    }

    final String initial = character.name.isNotEmpty
        ? character.name[0].toUpperCase()
        : '?';

    final double avatarSize = compact ? 24 : 34;
    Widget avatar;
    if (character.avatarPath != null && character.avatarPath!.isNotEmpty) {
      avatar = CircleAvatar(
        radius: avatarSize / 2,
        backgroundImage: FileImage(
          File(resolveGlazeFilePath(character.avatarPath!)!),
        ),
        onBackgroundImageError: (_, _) {},
        backgroundColor: avatarColor.withValues(alpha: 0.2),
        child: const SizedBox.shrink(),
      );
    } else {
      avatar = Container(
        width: avatarSize,
        height: avatarSize,
        decoration: BoxDecoration(
          color: avatarColor.withValues(alpha: 0.2),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Text(
            initial,
            style: TextStyle(
              fontSize: compact ? 12 : 16,
              color: avatarColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
    }

    if (compact) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTapAvatar,
            child: avatar,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTapInfo,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: character.name,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 14 * scale,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text: '   $sessionName',
                      style: TextStyle(
                        color: secondaryColor,
                        fontSize: 12 * scale,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(letterSpacing: letterSpacing),
              ),
            ),
          ),
          ?trailing,
        ],
      );
    }

    return Row(
      // With a trailing widget the block hugs its content, so it has a width
      // of its own that the desktop search field can take over.
      mainAxisSize: trailing == null ? MainAxisSize.max : MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTapAvatar,
          child: avatar,
        ),
        const SizedBox(width: 10),
        // With a trailing widget the text block only takes its own width, so
        // the trailing one lands right after the session line.
        Flexible(
          fit: trailing == null ? FlexFit.tight : FlexFit.loose,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTapInfo,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  character.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 16 * scale,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                    letterSpacing: letterSpacing,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sessionName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: secondaryColor,
                    fontSize: 12 * scale,
                    fontWeight: FontWeight.w400,
                    height: 1.1,
                    letterSpacing: letterSpacing,
                  ),
                ),
              ],
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}
