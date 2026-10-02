import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/db_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_block.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/image_viewer.dart';
import '../models/vn_document.dart';
import '../services/vn_sprite_image.dart';
import '../vn_labels.dart';
import '../vn_provider.dart';

/// The cast's sprites, every emotion of every character, so the player can
/// check them and have anyone who came out wrong drawn again, with a note on
/// what to change. Before the game starts it also accepts the cast or goes
/// on without pictures; in the game it only shows and redraws.
class VnCastReview extends ConsumerWidget {
  const VnCastReview({super.key, required this.sessionId, this.gate = false});

  final String sessionId;

  /// Whether the game waits on this review: adds accept and skip.
  final bool gate;

  /// The review as a sheet over the game.
  static Future<void> show(BuildContext context, String sessionId) {
    return GlazeBottomSheet.show<void>(
      context,
      title: 'vn_cast'.tr(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        child: VnCastReview(sessionId: sessionId),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(vnProvider(sessionId)).value;
    if (s == null) return const SizedBox.shrink();
    final notifier = ref.read(vnProvider(sessionId).notifier);
    final sprites = vnSpritesOf(s.session.sessionVars);
    final notes = vnArtNotesOf(s.session.sessionVars);
    final cast = s.doc.cast.values.toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (gate) ...[
          Text(
            'vn_cast_review_hint'.tr(),
            style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
        ],
        for (final who in cast)
          _CastCard(
            who: who,
            sprites: sprites[who.id] ?? const {},
            drawing: s.drawing == who.id,
            failure: s.artFailed[who.id],
            canDraw: s.drawsCast,
            onRedraw: () => unawaited(
              _askRedraw(context, notifier, who, notes[who.id] ?? ''),
            ),
          ),
        if (s.artError != null) ...[
          const SizedBox(height: 4),
          GlazeErrorBlock(message: vnErrorText(s.artError!)),
          const SizedBox(height: 8),
          GlazeActionButton(
            icon: Icons.refresh,
            label: 'vn_retry'.tr(),
            expand: true,
            onTap: () => unawaited(notifier.retryCast()),
          ),
        ],
        if (gate) ...[
          const SizedBox(height: 12),
          GlazeActionButton(
            icon: Icons.check,
            label: 'vn_cast_accept'.tr(),
            tone: GlazeActionTone.primary,
            expand: true,
            onTap: () => unawaited(notifier.approveCast()),
          ),
          const SizedBox(height: 8),
          GlazeActionButton(
            icon: Icons.hide_image_outlined,
            label: 'vn_cast_skip'.tr(),
            expand: true,
            onTap: () => unawaited(notifier.skipArt()),
          ),
        ],
      ],
    );
  }

  Future<void> _askRedraw(
    BuildContext context,
    VnNotifier notifier,
    VnCastMember who,
    String note,
  ) {
    return GlazeBottomSheet.show<void>(
      context,
      title: 'vn_cast_redraw_title'.tr(args: [who.name]),
      input: BottomSheetInput(
        placeholder: 'vn_cast_note'.tr(),
        value: note,
        confirmLabel: 'vn_cast_redraw'.tr(),
        onConfirm: (value) {
          Navigator.of(context, rootNavigator: true).pop();
          unawaited(notifier.redraw(who.id, value.trim()));
        },
      ),
    );
  }
}

class _CastCard extends ConsumerWidget {
  const _CastCard({
    required this.who,
    required this.sprites,
    required this.drawing,
    required this.failure,
    required this.canDraw,
    required this.onRedraw,
  });

  final VnCastMember who;
  final Map<String, String> sprites;
  final bool drawing;
  final Object? failure;
  final bool canDraw;
  final VoidCallback onRedraw;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storage = ref.watch(imageStorageProvider).value;
    final failure = this.failure;
    final String? status = drawing
        ? 'vn_cast_drawing'.tr()
        : failure is FormatException
        ? 'vn_cast_unusable'.tr()
        : failure != null
        ? 'vn_cast_failed'.tr()
        : sprites.isEmpty
        ? (canDraw ? 'vn_cast_waiting'.tr() : 'vn_cast_cardboard'.tr())
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          who.name,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: context.cs.onSurface,
                          ),
                        ),
                        if (status != null)
                          Text(
                            status,
                            style: TextStyle(
                              fontSize: 12,
                              color: failure != null
                                  ? context.cs.error
                                  : context.cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (drawing)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: GlazeSpinner(size: 18, strokeWidth: 2),
                    )
                  else if (canDraw)
                    IconButton(
                      icon: const Icon(Icons.brush_outlined),
                      tooltip: 'vn_cast_redraw'.tr(),
                      onPressed: onRedraw,
                    ),
                ],
              ),
              if (sprites.isNotEmpty && storage != null) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    children: [
                      for (final emotion in kVnEmotions)
                        Expanded(
                          child: _Sprite(
                            emotion: emotion,
                            path: sprites[emotion] == null
                                ? null
                                : storage.absolutePath(sprites[emotion]!) ??
                                      sprites[emotion],
                            name: who.name,
                          ),
                        ),
                    ],
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

/// One emotion: the sprite on a dark ground, where a green fringe or a hole
/// left by the cut-out shows; tapped, it opens full size.
class _Sprite extends StatelessWidget {
  const _Sprite({
    required this.emotion,
    required this.path,
    required this.name,
  });

  final String emotion;
  final String? path;
  final String name;

  @override
  Widget build(BuildContext context) {
    final path = this.path;
    final label = 'vn_emotion_$emotion'.tr();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        children: [
          GestureDetector(
            onTap: path == null
                ? null
                : () => ImageViewer.show(
                    context,
                    imageProvider: FileImage(File(path)),
                    description: '$name · $label',
                  ),
            child: Container(
              height: 150,
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A30),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.bottomCenter,
              child: path == null
                  ? Icon(
                      Icons.remove,
                      size: 16,
                      color: context.cs.onSurfaceVariant,
                    )
                  : Image.file(
                      File(path),
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.broken_image_outlined, size: 16),
                    ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
