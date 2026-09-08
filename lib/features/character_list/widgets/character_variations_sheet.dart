import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/character.dart';
import '../../../core/state/character_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/sheet_view.dart';
import 'character_card.dart';

/// Opens the variations grid for [groupId] as a modal sheet.
///
/// Shared by the library card and the character sheet so the presentation
/// options (root navigator, transparent background, safe area) stay in one
/// place — the sheet stacks over whatever opened it and returns nothing.
void showCharacterVariationsSheet(
  BuildContext context, {
  required String groupId,
  required String sourceId,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        CharacterVariationsSheet(groupId: groupId, sourceId: sourceId),
  );
}

/// The variations of one character group, as a grid of cards in the library's
/// visual language.
///
/// Each variation is a full character row sharing a [Character.variantGroupId];
/// the row at order 0 is the original the group grew out of. Order is creation
/// order and the user cannot change it — a reassignable "main" variation is the
/// confusion this screen exists to avoid.
///
/// Tapping a card opens that variation's own character sheet, which is where
/// editing, chats and the gallery live.
class CharacterVariationsSheet extends ConsumerWidget {
  final String groupId;

  /// The variation this sheet was opened from. New variations are cloned from
  /// it — cloning the original regardless of where the user came from meant
  /// "add variation" on a variation silently duplicated a different character.
  final String sourceId;

  const CharacterVariationsSheet({
    super.key,
    required this.groupId,
    required this.sourceId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final variants =
        ref.watch(characterVariantsProvider(groupId)).value ??
        const <Character>[];

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
      // a CustomScrollView does not, and without this the first row of cards
      // scrolls under the header instead of below it.
      body: Builder(
        builder: (context) {
          final inset = MediaQuery.paddingOf(context);
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: inset.top + 8)),
              SliverGrid(
                // Same delegate as the library grid, so a variation card reads
                // as the same kind of object as the card you came from.
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 2 / 3,
                    ),
                delegate: SliverChildBuilderDelegate((context, i) {
                  final variant = variants[i];
                  return CharacterCard(
                    key: ValueKey(variant.id),
                    character: variant,
                    inVariationsGrid: true,
                  );
                }, childCount: variants.length),
              ),
              // Trailing room so the last row can scroll clear of the FAB.
              SliverToBoxAdapter(
                child: SizedBox(height: inset.bottom + kVariationsFabClearance),
              ),
            ],
          );
        },
      ),
    );
  }

  /// The variation new copies are cloned from: the one this sheet was opened
  /// from, falling back to the original if it has since been deleted.
  Character _source(List<Character> variants) =>
      variants.where((v) => v.id == sourceId).firstOrNull ?? variants.first;

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
}

/// Height reserved below the last row so it can scroll clear of the FAB
/// (48pt button + the 16pt margin SheetView positions it with, plus air).
const double kVariationsFabClearance = 80;

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
