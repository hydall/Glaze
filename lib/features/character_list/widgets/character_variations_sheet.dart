import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/character_tokens.dart';
import '../../../core/models/character.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/utils/platform_paths.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/utils/variant_label.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../character_editor_screen.dart';

/// Manages the variations of one character group: list, reorder, add (a copy of
/// the variation the sheet was opened from), rename, duplicate, edit and delete.
///
/// Each variation is a full character card sharing a [Character.variantGroupId];
/// the row at order 0 is the group's cover — the single card the library grid
/// shows for the whole group.
///
/// Pops with the id of the variation the user tapped, or `null` when dismissed.
/// Picking a variation means "I want to play with this one", so resolving that
/// id into a chat is the caller's job; editing lives in the per-row menu.
class CharacterVariationsSheet extends ConsumerWidget {
  final String groupId;

  /// The variation whose screen opened this sheet. New variations are cloned
  /// from it — copying the cover regardless of where the user came from meant
  /// "add variation" on a variation silently duplicated a different character.
  final String sourceId;

  const CharacterVariationsSheet({
    super.key,
    required this.groupId,
    required this.sourceId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final variantsAsync = ref.watch(characterVariantsProvider(groupId));
    final variants = variantsAsync.value ?? const <Character>[];
    final sessionCounts =
        ref.watch(characterSessionCountsProvider).value ?? const <String, int>{};

    return SheetView(
      title: 'variations_title'.tr(),
      showHandle: true,
      bodyPadding: const EdgeInsets.symmetric(horizontal: 16),
      floatingActionButton: variants.isEmpty
          ? null
          : _AddVariationFab(
              onTap: () => _promptAdd(context, ref, _source(variants), variants),
            ),
      // Builder so the padding read below is the one SheetView injects for its
      // header and the nav bar. A ListView would consume that automatically;
      // CustomScrollView does not, and without this the first rows scroll under
      // the header instead of below it.
      body: Builder(
        builder: (context) {
          final inset = MediaQuery.paddingOf(context);
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: inset.top + 8)),
              if (variants.length > 1)
                SliverToBoxAdapter(child: _ReorderHint(count: variants.length)),
              SliverReorderableList(
                itemCount: variants.length,
                onReorderItem: (oldIndex, newIndex) =>
                    _reorder(ref, variants, oldIndex, newIndex),
                itemBuilder: (context, i) {
                  final variant = variants[i];
                  return _VariationTile(
                    // Keyed by id so the reorder animation follows the row, not
                    // the slot it happened to occupy.
                    key: ValueKey(variant.id),
                    index: i,
                    variant: variant,
                    isCover: i == 0,
                    sessionCount: sessionCounts[variant.id] ?? 0,
                    draggable: variants.length > 1,
                    onTap: () => Navigator.of(
                      context,
                      rootNavigator: true,
                    ).pop(variant.id),
                    onMore: () => _variantActions(context, ref, variants, i),
                  );
                },
              ),
              // Trailing room so the last row can scroll clear of the FAB.
              SliverToBoxAdapter(
                child: SizedBox(height: inset.bottom + _kFabClearance),
              ),
            ],
          );
        },
      ),
    );
  }

  /// The variation new copies are cloned from: the one this sheet was opened
  /// from, falling back to the cover if it has since been deleted.
  Character _source(List<Character> variants) =>
      variants.where((v) => v.id == sourceId).firstOrNull ?? variants.first;

  void _reorder(
    WidgetRef ref,
    List<Character> variants,
    int oldIndex,
    int newIndex,
  ) {
    // onReorderItem already adjusts newIndex for the removed row, so this is a
    // straight remove-then-insert.
    if (newIndex == oldIndex) return;
    final ordered = [for (final v in variants) v.id];
    ordered.insert(newIndex, ordered.removeAt(oldIndex));
    ref.read(charactersProvider.notifier).reorderVariants(groupId, ordered);
  }

  void _promptAdd(
    BuildContext context,
    WidgetRef ref,
    Character source,
    List<Character> variants,
  ) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'variation_add'.tr(),
      input: BottomSheetInput(
        placeholder: 'variation_name'.tr(),
        // Prefilled so creating a variation is one confirm, not a naming task.
        value: _defaultVariantName(variants),
        confirmLabel: 'btn_create'.tr(),
        onConfirm: (val) async {
          Navigator.of(context, rootNavigator: true).pop();
          await ref
              .read(charactersProvider.notifier)
              .addVariant(source, val.trim());
        },
      ),
    );
  }

  /// A free "Variation N" name, skipping numbers already taken in the group.
  String _defaultVariantName(List<Character> variants) {
    final taken = {
      for (final v in variants)
        if (v.variantName?.trim().isNotEmpty == true) v.variantName!.trim(),
    };
    for (var n = variants.length; n < variants.length + 100; n++) {
      final candidate = 'variation_default_name'.tr(
        namedArgs: {'n': '${n + 1}'},
      );
      if (!taken.contains(candidate)) return candidate;
    }
    return '';
  }

  /// Per-row menu. Resolves to an action string and acts *after* the menu route
  /// is gone: popping this sheet from inside the menu's own `onTap` chains two
  /// pops on the same navigator, which races the menu's exit animation.
  Future<void> _variantActions(
    BuildContext context,
    WidgetRef ref,
    List<Character> variants,
    int index,
  ) async {
    final variant = variants[index];
    final isCover = index == 0;
    final rootNav = Navigator.of(context, rootNavigator: true);
    final action = await GlazeBottomSheet.show<String>(
      context,
      title: variantLabel(variant),
      items: [
        BottomSheetItem(
          icon: Icons.chat_bubble_outline_rounded,
          label: 'btn_open_chat'.tr(),
          onTap: () => rootNav.pop('chat'),
        ),
        BottomSheetItem(
          icon: Icons.edit_outlined,
          label: 'action_edit'.tr(),
          onTap: () => rootNav.pop('edit'),
        ),
        BottomSheetItem(
          icon: Icons.drive_file_rename_outline,
          label: 'action_rename'.tr(),
          onTap: () => rootNav.pop('rename'),
        ),
        BottomSheetItem(
          icon: Icons.copy_all_outlined,
          label: 'variation_duplicate'.tr(),
          hint: 'variation_duplicate_hint'.tr(),
          onTap: () => rootNav.pop('duplicate'),
        ),
        if (!isCover)
          BottomSheetItem(
            icon: Icons.star_outline_rounded,
            label: 'variation_make_cover'.tr(),
            hint: 'variation_make_cover_hint'.tr(),
            onTap: () => rootNav.pop('cover'),
          ),
        BottomSheetItem(
          icon: Icons.delete_outline,
          label: 'variation_delete'.tr(),
          isDestructive: true,
          onTap: () => rootNav.pop('delete'),
        ),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'chat':
        Navigator.of(context, rootNavigator: true).pop(variant.id);
      case 'edit':
        _openEditor(context, variant.id);
      case 'rename':
        _promptRename(context, ref, variant);
      case 'duplicate':
        _promptAdd(context, ref, variant, variants);
      case 'cover':
        await ref.read(charactersProvider.notifier).reorderVariants(groupId, [
          variant.id,
          for (final v in variants)
            if (v.id != variant.id) v.id,
        ]);
      case 'delete':
        await _confirmDelete(context, ref, variant, variants.length);
    }
  }

  /// Pushes the editor on the root navigator so it stacks *above* this sheet
  /// and popping it returns here — routing through GoRouter would insert it as
  /// a declarative page below the imperatively-pushed sheet instead.
  void _openEditor(BuildContext context, String charId) {
    final isIos = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final editor = CharacterEditorScreen(charId: charId);
    Navigator.of(context, rootNavigator: true).push(
      isIos
          ? CupertinoPageRoute<void>(builder: (_) => editor)
          : MaterialPageRoute<void>(builder: (_) => editor),
    );
  }

  void _promptRename(BuildContext context, WidgetRef ref, Character variant) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'action_rename'.tr(),
      input: BottomSheetInput(
        placeholder: 'variation_name'.tr(),
        value: variant.variantName ?? '',
        confirmLabel: 'btn_save'.tr(),
        onConfirm: (val) {
          Navigator.of(context, rootNavigator: true).pop();
          ref
              .read(charactersProvider.notifier)
              .renameVariant(variant.id, val.trim());
        },
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Character variant,
    int groupSize,
  ) async {
    final rootNav = Navigator.of(context, rootNavigator: true);
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'variation_delete'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        // Name the variation being deleted: two rows with the same avatar are
        // easy to mix up, and this is not undoable.
        description:
            '${variantLabel(variant)}\n${'variation_delete_confirm'.tr()}',
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () => rootNav.pop(true),
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => rootNav.pop(false),
        ),
      ],
    );
    if (confirmed != true || !context.mounted) return;
    // Deleting the last variation deletes the character itself, so close the
    // sheet rather than leave it staring at an empty list. Popped only after
    // the confirm route is gone — chaining both pops races its exit animation.
    if (groupSize <= 1) Navigator.of(context, rootNavigator: true).pop();
    await ref.read(charactersProvider.notifier).remove(variant.id);
  }
}

/// Height reserved below the last row so it can scroll clear of the FAB
/// (48pt button + the 16pt margin SheetView positions it with, plus air).
const double _kFabClearance = 80;

/// "Add variation" as a floating pill, mirroring the character sheet's chat
/// FAB. It used to be the first row of the list, where the sheet header sat on
/// top of it and it read as part of the content rather than the primary action.
class _AddVariationFab extends StatelessWidget {
  final VoidCallback onTap;

  const _AddVariationFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: context.cs.primary,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(blurRadius: 16, color: Color(0x80000000)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.add_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(
              'variation_add'.tr(),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line explaining what the order means, so the cover concept doesn't have
/// to be inferred from an unlabelled star.
class _ReorderHint extends StatelessWidget {
  final int count;

  const _ReorderHint({required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(
        '${'variations_count'.plural(count)} · ${'variations_reorder_hint'.tr()}',
        style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
      ),
    );
  }
}

class _VariationTile extends StatelessWidget {
  final int index;
  final Character variant;
  final bool isCover;
  final int sessionCount;
  final bool draggable;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const _VariationTile({
    super.key,
    required this.index,
    required this.variant,
    required this.isCover,
    required this.sessionCount,
    required this.draggable,
    required this.onTap,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onLongPress: onMore,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              children: [
                _avatar(context),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              variantLabel(variant),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: context.cs.onSurface,
                              ),
                            ),
                          ),
                          if (isCover) ...[
                            const SizedBox(width: 8),
                            const _CoverChip(),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _meta(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    color: context.cs.onSurfaceVariant,
                  ),
                  onPressed: onMore,
                ),
                if (draggable)
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8, left: 2),
                      child: Icon(
                        Icons.drag_handle_rounded,
                        color: context.cs.onSurfaceVariant.withValues(
                          alpha: 0.7,
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

  /// "N chats · M tokens" — the two facts that actually distinguish variations
  /// that share a name stem and an avatar.
  String _meta() {
    final tokens = variant.tokenCount > 0
        ? variant.tokenCount
        : estimateCharacterTokens(variant);
    final parts = <String>[
      '$sessionCount ${'count_chats'.plural(sessionCount)}',
      if (tokens > 0) '${_formatTokens(tokens)} ${'label_tokens'.tr()}',
    ];
    return parts.join(' · ');
  }

  String _formatTokens(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}kk';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  Widget _avatar(BuildContext context) {
    final path = variant.avatarPath;
    final resolved = (path != null && path.isNotEmpty)
        ? resolveGlazeFilePath(path)
        : null;
    return ClipOval(
      child: SizedBox.square(
        dimension: 44,
        child: resolved != null
            ? Image.file(
                File(resolved),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _placeholder(context),
              )
            : _placeholder(context),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      color: context.cs.primary,
      alignment: Alignment.center,
      child: Text(
        variant.name.isNotEmpty ? variant.name[0].toUpperCase() : '?',
        style: const TextStyle(color: Colors.black, fontSize: 16),
      ),
    );
  }
}

/// Labelled marker for the group's cover, replacing the bare star: the row that
/// carries it is the one the library grid shows for the whole group.
class _CoverChip extends StatelessWidget {
  const _CoverChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: context.cs.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 12, color: context.cs.primary),
          const SizedBox(width: 4),
          Text(
            'variation_cover'.tr(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: context.cs.primary,
            ),
          ),
        ],
      ),
    );
  }
}
