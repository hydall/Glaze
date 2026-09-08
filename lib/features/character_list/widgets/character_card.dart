import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/character.dart';
import '../../../core/services/character_export_helper.dart';
import '../../../core/state/character_folder_provider.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/utils/platform_paths.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/card_tag_chips.dart';
import '../../../shared/widgets/dust_disintegration.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../character_detail_screen.dart';
import 'character_hiding_onboarding_sheet.dart';
import 'character_variations_sheet.dart';
import '../../../shared/widgets/variation_chip.dart';
import '../../../shared/utils/variant_label.dart';
import '../../../core/llm/character_tokens.dart';
import '../character_selection_provider.dart';
import 'add_to_folder_sheet.dart';

class CharacterCard extends ConsumerStatefulWidget {
  final Character character;
  final Duration entryDelay;

  /// When the card is shown inside a folder, this is that folder's id — it
  /// enables the "Remove from folder" action.
  final String? folderId;

  /// True when this card stands for one variation inside the variations grid
  /// rather than for a whole group in the library.
  ///
  /// In the library a card is the group's original and tapping it drills into
  /// the group; in the grid a card is a concrete variation and tapping it opens
  /// that variation. The differences are small enough that one flag beats a
  /// second near-identical widget — see the branches that read it.
  final bool inVariationsGrid;

  const CharacterCard({
    super.key,
    required this.character,
    this.entryDelay = Duration.zero,
    this.folderId,
    this.inVariationsGrid = false,
  });

  @override
  ConsumerState<CharacterCard> createState() => _CharacterCardState();
}

class _CharacterCardState extends ConsumerState<CharacterCard>
    with TickerProviderStateMixin {
  bool _pressed = false;
  bool _hovered = false;
  int _tokenCount = 0;
  late final AnimationController _entryCtrl;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _scaleAnim;

  /// Snapshot boundary + dust state for the iOS-style delete animation.
  final GlobalKey _boundaryKey = GlobalKey();
  late final AnimationController _dustCtrl;
  DustParticles? _dust;

  Character get character => widget.character;

  /// Variation group this card represents. Legacy rows can still carry an empty
  /// group id, in which case the character is its own group.
  String get _groupId => character.variantGroupId.isEmpty
      ? character.id
      : character.variantGroupId;

  String get _displayName {
    final displayName = character.displayName?.trim();
    return (displayName != null && displayName.isNotEmpty)
        ? displayName
        : character.name;
  }

  /// The corner count badge belongs to the library, where it says "there is
  /// more behind this card". Inside the grid every card would repeat the same
  /// number about the group you are already looking at.
  bool _showsVariationsBadge(int variantCount) =>
      !widget.inVariationsGrid && variantCount > 1;

  /// Prefer the cached count persisted on import/save; fall back to a live
  /// (memoized) estimate only for rows that predate the cached column.
  int _resolveTokens(Character c) =>
      c.tokenCount > 0 ? c.tokenCount : estimateCharacterTokens(c);

  @override
  void initState() {
    super.initState();
    _tokenCount = _resolveTokens(widget.character);
    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _dustCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    final curve = CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOut);
    _fadeAnim = curve;
    _scaleAnim = Tween<double>(begin: 0.9, end: 1.0).animate(curve);
    if (widget.entryDelay > Duration.zero) {
      Future.delayed(widget.entryDelay, () {
        if (mounted) _entryCtrl.forward();
      });
    } else {
      _entryCtrl.forward();
    }
  }

  @override
  void didUpdateWidget(CharacterCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.character != widget.character) {
      _tokenCount = _resolveTokens(widget.character);
    }
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    _dustCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(avatarVersionProvider);
    // The bulk-delete flow marks every selected id at once; each card starts its
    // own dust animation here so they all crumble together (not one-by-one). The
    // actual row removal is batched by the screen after the sweep.
    ref.listen<bool>(
      characterDisintegrationProvider.select((s) => s.contains(character.id)),
      (prev, next) {
        if (next && _dust == null) _playDust();
      },
    );

    // Bulk selection belongs to the library. Inside the variations grid a
    // long-press would select sibling rows whose bulk actions then apply to the
    // whole group anyway — a gesture that cannot mean what it looks like.
    final selectionActive =
        !widget.inVariationsGrid &&
        ref.watch(characterSelectionProvider.select((s) => s.active));
    final selected =
        !widget.inVariationsGrid &&
        ref.watch(
          characterSelectionProvider.select((s) => s.contains(character.id)),
        );
    final scale = _pressed ? 0.96 : (_hovered ? 1.01 : 1.0);
    final dy = _hovered && !_pressed ? -4.0 : 0.0;
    // In the library the card stands for a whole variation group, so the
    // favorite accent comes from group-level stats — a favorite living on a
    // non-original variation must still light this card up.
    final groupStats = variantGroupStatsOf(ref, _groupId);
    final isFav = groupStats.anyFav;
    final variantCount = groupStats.count;
    // The chip names the variation this card *is*: the group's original in the
    // library, the variation itself in the grid. A lone character has nothing
    // to disambiguate, so it gets no chip.
    final variationLabel = (widget.inVariationsGrid || variantCount > 1)
        ? variantLabel(character)
        : null;
    final shadowAlpha = _hovered
        ? (isFav ? 0.25 : 0.3)
        : 0.1;
    final shadowColor = isFav && _hovered
        ? const Color(0xFFFF6B6B).withValues(alpha: shadowAlpha)
        : Colors.black.withValues(alpha: shadowAlpha);

    // Once a delete is triggered the card is replaced in-place by its dust
    // cloud: the sampled particles scatter while the grid keeps the slot until
    // the animation ends and the character is actually removed.
    if (_dust != null) {
      return FadeTransition(
        opacity: _fadeAnim,
        child: ScaleTransition(
          scale: _scaleAnim,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _dustCtrl,
              builder: (_, _) => CustomPaint(
                painter: DustPainter(_dust!, _dustCtrl.value),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
    }

    return FadeTransition(
      opacity: _fadeAnim,
      child: ScaleTransition(
        scale: _scaleAnim,
      child: RepaintBoundary(
        key: _boundaryKey,
        child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: () {
            if (selectionActive) {
              ref.read(characterSelectionProvider.notifier).toggle(character.id);
            } else {
              _handleTap(context, variantCount);
            }
          },
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onLongPress: widget.inVariationsGrid
              ? null
              : () {
                  final notifier = ref.read(
                    characterSelectionProvider.notifier,
                  );
                  if (selectionActive) {
                    notifier.toggle(character.id);
                  } else {
                    notifier.start(character.id);
                  }
                },
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
                    child: _buildImage(),
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
                    child: _CardInfo(
                      character: character,
                      tokenCount: _tokenCount,
                      isFav: isFav,
                      variationLabel: variationLabel,
                      // Inside the grid the chip is a label, not a door: every
                      // card would otherwise reopen the sheet you are already in.
                      onVariationTap: widget.inVariationsGrid
                          ? null
                          : () => _showVariations(context),
                    ),
                  ),
                  if (character.hidden || _showsVariationsBadge(variantCount))
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Row(
                        children: [
                          if (character.hidden) const _HiddenBadge(),
                          if (character.hidden &&
                              _showsVariationsBadge(variantCount))
                            const SizedBox(width: 6),
                          if (_showsVariationsBadge(variantCount))
                            _VariationsBadge(count: variantCount),
                        ],
                      ),
                    ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: selectionActive
                        ? _SelectionCheck(selected: selected)
                        : _CardMenuButton(
                            character: character,
                            onTap: () => _showActions(
                              context,
                              ref,
                              isFav: isFav,
                              variantCount: variantCount,
                            ),
                          ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: selected
                                ? context.cs.primary
                                : isFav
                                    ? const Color(0xFFFF6B6B)
                                    : Colors.white.withValues(alpha: 0.15),
                            width: selected ? 3 : 2,
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
      ),
      ),
      ),
    );
  }

  Widget _buildImage() {
    final avatarPath = character.avatarPath;
    if (avatarPath == null || avatarPath.isEmpty) return _buildPlaceholder();
    // Prefer the pre-generated 512px thumbnail so first-scroll doesn't have to
    // decode the full-resolution PNG per card (jank + delayed pop-in). Falls
    // back to the source avatar when a thumbnail hasn't been generated yet.
    final resolved = resolveGlazeThumbnailPath(avatarPath);
    if (resolved == null) return _buildPlaceholder();
    final mq = MediaQuery.of(context);
    // Decode to roughly the card's on-screen width (two columns) regardless of
    // source: caps memory for the larger aspect-preserving thumbnails and the
    // full-res fallback alike, while keeping the portrait crisp (no upscaling).
    final cacheWidth = (mq.size.width * mq.devicePixelRatio / 2).ceil();
    return Image(
      image: ResizeImage(
        FileImage(File(resolved)),
        width: cacheWidth,
        allowUpscaling: false,
      ),
      fit: BoxFit.cover,
      filterQuality: FilterQuality.high,
      errorBuilder: (_, _, _) => _buildPlaceholder(),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: _avatarColor().withValues(alpha: 0.2),
      child: Center(
        child: Text(
          _displayName.isNotEmpty ? _displayName[0].toUpperCase() : '?',
          style: TextStyle(
            fontSize: 48,
            color: _avatarColor(),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Color _avatarColor() {
    if (character.color != null) {
      try {
        final c = character.color!.replaceFirst('#', '');
        return Color(int.parse('FF$c', radix: 16));
      } catch (_) {}
    }
    return context.cs.primary;
  }

  /// Where a tap on the card lands.
  ///
  /// In the library a card with variations is a *group*, so it drills into the
  /// grid — asking "which one" before showing a character sheet that could only
  /// ever have been one of them. Everything else opens the character directly.
  void _handleTap(BuildContext context, int variantCount) {
    if (!widget.inVariationsGrid && variantCount > 1) {
      _showVariations(context);
    } else {
      _showDetailSheet(context);
    }
  }

  void _showDetailSheet(BuildContext context) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CharacterDetailScreen(charId: character.id),
    );
    if (result != null && result.isNotEmpty && context.mounted) {
      context.go(result);
    }
  }

  void _showActions(
    BuildContext context,
    WidgetRef ref, {
    required bool isFav,
    required int variantCount,
  }) {
    GlazeBottomSheet.show<void>(
      context,
      items: [
        BottomSheetItem(
          icon: Icons.share_rounded,
          label: 'action_export'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _showExportOptions(context);
          },
        ),
        BottomSheetItem(
          icon: Icons.edit_rounded,
          label: 'action_edit'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            context.push('/character/${character.id}/edit');
          },
        ),
        // Renaming and duplicating are per-variation, so they only belong to a
        // card that stands for one; in the library the card is a whole group.
        if (widget.inVariationsGrid) ...[
          BottomSheetItem(
            icon: Icons.drive_file_rename_outline,
            label: 'action_rename'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _promptRenameVariation(context, ref);
            },
          ),
          BottomSheetItem(
            icon: Icons.copy_all_outlined,
            label: 'variation_duplicate'.tr(),
            hint: 'variation_duplicate_hint'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              ref
                  .read(charactersProvider.notifier)
                  .addVariant(character, '');
            },
          ),
        ] else
          // Same entry point as the detail sheet's menu — the card menu used to
          // omit it entirely, so variations were reachable only two levels deep.
          BottomSheetItem(
            icon: Icons.dynamic_feed_rounded,
            label: 'variations_title'.tr(),
            hint: variantCount > 1
                ? 'variations_count'.plural(variantCount)
                : 'variations_hint_single'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _showVariations(context);
            },
          ),
        BottomSheetItem(
          icon: Icons.favorite,
          label: isFav ? 'action_remove_fav'.tr() : 'action_add_fav'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            // Group-wide: the card reads as favorited when any variation is, so
            // writing only the original would leave "remove" looking like a no-op.
            ref
                .read(charactersProvider.notifier)
                .setGroupFav(character.id, !isFav);
          },
        ),
        BottomSheetItem(
          icon: character.hidden
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
          label: character.hidden ? 'action_unhide'.tr() : 'action_hide'.tr(),
          onTap: () {
            final willHide = !character.hidden;
            Navigator.of(context, rootNavigator: true).pop();
            ref
                .read(charactersProvider.notifier)
                .setHidden(character.id, willHide);
            GlazeToast.show(
              context,
              character.hidden
                  ? 'char_unhidden_toast'.tr()
                  : 'char_hidden_toast'.tr(),
            );
            if (willHide) {
              maybeShowCharacterHidingOnboarding(context);
            }
          },
        ),
        BottomSheetItem(
          icon: Icons.create_new_folder_outlined,
          label: 'action_add_to_folder'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              useRootNavigator: true,
              useSafeArea: true,
              backgroundColor: Colors.transparent,
              builder: (_) => AddToFolderSheet(characterId: character.id),
            );
          },
        ),
        if (widget.folderId != null)
          BottomSheetItem(
            icon: Icons.folder_off_outlined,
            label: 'action_remove_from_folder'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              ref
                  .read(characterFolderRepoProvider)
                  .removeMember(widget.folderId!, character.id);
            },
          ),
        BottomSheetItem(
          icon: Icons.delete_rounded,
          label: 'action_delete'.tr(),
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _confirmDelete(context, ref);
          },
        ),
      ],
    );
  }

  /// Opens the variations grid for this card's group. Picking a card there
  /// opens that variation's own sheet on top, so nothing comes back here.
  void _showVariations(BuildContext context) {
    showCharacterVariationsSheet(
      context,
      groupId: _groupId,
      sourceId: character.id,
    );
  }

  void _promptRenameVariation(BuildContext context, WidgetRef ref) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'action_rename'.tr(),
      input: BottomSheetInput(
        placeholder: 'variation_name'.tr(),
        value: character.variantName ?? '',
        confirmLabel: 'btn_save'.tr(),
        onConfirm: (val) {
          Navigator.of(context, rootNavigator: true).pop();
          ref
              .read(charactersProvider.notifier)
              .renameVariant(character.id, val.trim());
        },
      ),
    );
  }

  void _showExportOptions(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'Export $_displayName',
      items: [
        BottomSheetItem(
          icon: Icons.image_outlined,
          label: 'label_export_png'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _export(context, 'png');
          },
        ),
        BottomSheetItem(
          icon: Icons.code_rounded,
          label: 'label_export_json'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _export(context, 'json');
          },
        ),
        BottomSheetItem(
          icon: Icons.folder_zip_rounded,
          label: 'label_export_zip'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _export(context, 'zip');
          },
        ),
      ],
    );
  }

  Future<void> _export(BuildContext context, String format) async {
    try {
      final savedPath = await exportCharacterToFile(
        ref: ref,
        character: character,
        format: format,
      );
      if (context.mounted) {
        GlazeToast.show(
          context,
          'Exported ${format.toUpperCase()} to $savedPath',
        );
      }
    } catch (e) {
      if (context.mounted) {
        GlazeErrorDialog.show(context, e, prefix: 'Export failed: ');
      }
    }
  }


  void _confirmDelete(BuildContext context, WidgetRef ref) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'action_delete_char'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'Delete $_displayName? This cannot be undone.',
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await _disintegrate();
          },
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.pop(context),
        ),
      ],
    );
  }

  /// Plays the iOS-style "crumble to dust" animation in place, then removes the
  /// character. Capture the notifier up front so the deletion still lands even
  /// though this card unmounts the instant [remove] rebuilds the grid.
  Future<void> _disintegrate() async {
    if (_dust != null) return; // already dissolving
    final notifier = ref.read(charactersProvider.notifier);
    final played = await _playDust();
    if (!played) {
      // Couldn't snapshot (e.g. unmounted) — fall back to an instant delete.
      await notifier.remove(character.id);
      return;
    }
    await notifier.remove(character.id);
  }

  /// Snapshots the card and runs its dust animation to completion, leaving the
  /// scattered particles painted in place. Returns `false` when the boundary
  /// couldn't be captured. Used both by the single-card delete ([_disintegrate])
  /// and — driven by [characterDisintegrationProvider] — by the bulk delete,
  /// where the screen batch-removes the rows once the sweep has run.
  Future<bool> _playDust() async {
    if (_dust != null) return true; // already dissolving
    final data = await DustParticles.capture(_boundaryKey);
    if (!mounted || data == null) return false;
    setState(() => _dust = data);
    await _dustCtrl.forward(from: 0);
    return true;
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

class _CardInfo extends StatelessWidget {
  final Character character;
  final int tokenCount;

  /// Group-wide favorite flag — passed in rather than read off [character],
  /// which is only one row of the group.
  final bool isFav;

  /// Name of the variation this card represents, or null for a lone character
  /// that has nothing to disambiguate.
  final String? variationLabel;

  /// Tapping the chip drills into the group. Null makes the chip a plain label.
  final VoidCallback? onVariationTap;

  const _CardInfo({
    required this.character,
    required this.tokenCount,
    required this.isFav,
    required this.variationLabel,
    required this.onVariationTap,
  });

  String get _displayName {
    final displayName = character.displayName?.trim();
    return (displayName != null && displayName.isNotEmpty)
        ? displayName
        : character.name;
  }

  @override
  Widget build(BuildContext context) {
    const favColor = Color(0xFFFF6B6B);

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (variationLabel != null) ...[
            // Above the name, so the card answers "which variation is this?"
            // before you read whose it is. The Column is bottom-anchored and
            // grows upward into the gradient, so the extra line costs no name
            // space. Opaque hit test so the tap does not fall through to the
            // card underneath.
            GestureDetector(
              onTap: onVariationTap,
              behavior: HitTestBehavior.opaque,
              child: VariationChip(name: variationLabel!, maxWidth: 140),
            ),
            const SizedBox(height: 4),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isFav) ...[
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Icon(
                    Icons.favorite,
                    size: 14,
                    color: favColor,
                    shadows: [Shadow(blurRadius: 2, color: Colors.black54)],
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  _displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: isFav ? favColor : Colors.white,
                    shadows: const [
                      Shadow(blurRadius: 4, color: Colors.black54),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (tokenCount > 0) ...[
            const SizedBox(height: 2),
            Text(
              '${_formatTokens(tokenCount)} tokens',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.6),
                shadows: const [Shadow(blurRadius: 4, color: Colors.black87)],
              ),
            ),
          ],
          if (character.tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            CardTagChips(tags: character.tags, max: 4),
          ],
        ],
      ),
    );
  }

  String _formatTokens(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}kk';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}



class _SelectionCheck extends StatelessWidget {
  final bool selected;

  const _SelectionCheck({required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: selected
            ? context.cs.primary
            : Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: selected ? 0.9 : 0.6),
          width: 2,
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
          : null,
    );
  }
}

class _HiddenBadge extends StatelessWidget {
  const _HiddenBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: const Icon(
        Icons.visibility_off_rounded,
        size: 18,
        color: Colors.white,
      ),
    );
  }
}

/// Corner badge marking a card that stands for a variation group, with the
/// number of variations it collapses.
///
/// Without it a group of five was pixel-identical to a lone character, which is
/// why nobody found the feature: there was nothing on the card to suggest more
/// was hiding behind it.
class _VariationsBadge extends StatelessWidget {
  final int count;

  const _VariationsBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.dynamic_feed_rounded,
            size: 15,
            color: Colors.white,
          ),
          const SizedBox(width: 4),
          Text(
            '$count',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _CardMenuButton extends StatelessWidget {
  final Character character;
  final VoidCallback onTap;

  const _CardMenuButton({required this.character, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.15),
            width: 1,
          ),
        ),
        child: const Icon(
          Icons.more_vert_rounded,
          size: 18,
          color: Colors.white,
        ),
      ),
    );
  }
}
