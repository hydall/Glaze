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

  const ChatHeader({
    super.key,
    required this.character,
    required this.sessionName,
    this.currentSessionIndex = 0,
    this.onTapInfo,
    this.onTapAvatar,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(avatarVersionProvider);
    final preset = ref.watch(themeProvider.select((s) => s.activePreset));
    final scale =
        preset.uiFontSize is num ? preset.uiFontSizeValue / 15.0 : 1.0;
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

    Widget avatar;
    if (character.avatarPath != null && character.avatarPath!.isNotEmpty) {
      avatar = CircleAvatar(
        radius: 17,
        backgroundImage: FileImage(File(resolveGlazeFilePath(character.avatarPath!)!)),
        onBackgroundImageError: (_, _) {},
        backgroundColor: avatarColor.withValues(alpha: 0.2),
        child: const SizedBox.shrink(),
      );
    } else {
      avatar = Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: avatarColor.withValues(alpha: 0.2),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Text(
            initial,
            style: TextStyle(
              fontSize: 16,
              color: avatarColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTapAvatar,
          child: avatar,
        ),
        const SizedBox(width: 10),
        Expanded(
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
      ],
    );
  }

}
