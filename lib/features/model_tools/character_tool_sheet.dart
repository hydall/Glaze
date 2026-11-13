import 'dart:io';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/navigation/router.dart' show rootNavigatorKey;
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_expansion_tile.dart';
import '../../shared/widgets/glass_surface.dart';
import 'character_tool_proposal.dart';

/// Sheets waiting on one another, so two calls — or two chats generating at
/// once — never stack their questions.
Future<void> _queue = Future.value();

/// Asks the user to approve a character write a chat model asked for.
///
/// Generation has no context of its own, so the sheet goes on the root
/// navigator, wherever the user is. True on approval, false on decline or
/// dismissal, null when no navigator is mounted to ask on.
Future<bool?> showCharacterProposalSheet(CharacterToolProposal proposal) {
  final answer = _queue.then((_) => _show(proposal));
  _queue = answer.then((_) {}, onError: (_) {});
  return answer;
}

Future<bool?> _show(CharacterToolProposal proposal) async {
  final context = rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return null;
  final isCreate = proposal.kind == CharacterProposalKind.create;
  void close(bool value) =>
      Navigator.of(context, rootNavigator: true).pop(value);

  final answer = await GlazeBottomSheet.show<bool>(
    context,
    title:
        (isCreate
                ? 'model_tools_confirm_create_title'
                : 'model_tools_confirm_update_title')
            .tr(namedArgs: {'name': proposal.characterName}),
    source: 'model_tools_confirm_source'.tr(),
    child: _ProposalBody(proposal: proposal),
    items: [
      BottomSheetItem(
        label:
            (isCreate
                    ? 'model_tools_confirm_create'
                    : 'model_tools_confirm_update')
                .tr(),
        icon: Icons.check_rounded,
        onTap: () => close(true),
      ),
      BottomSheetItem(
        label: 'model_tools_confirm_reject'.tr(),
        icon: Icons.block_rounded,
        isDestructive: true,
        onTap: () => close(false),
      ),
    ],
  );
  return answer ?? false;
}

class _ProposalBody extends StatelessWidget {
  const _ProposalBody({required this.proposal});

  final CharacterToolProposal proposal;

  @override
  Widget build(BuildContext context) {
    final isUpdate = proposal.kind == CharacterProposalKind.update;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (proposal.avatar case final avatar?)
              _AvatarChange(
                after: avatar,
                beforePath: isUpdate ? proposal.currentAvatarPath : null,
                divider:
                    proposal.changes.isNotEmpty ||
                    proposal.lorebookEntryCount > 0,
              ),
            for (final (i, change) in proposal.changes.indexed)
              GlazeExpansionTile(
                showDivider:
                    i < proposal.changes.length - 1 ||
                    proposal.lorebookEntryCount > 0,
                title: Text(change.field.labelKey.tr()),
                subtitle: Text(
                  _preview(change.after),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
                children: [
                  if (isUpdate) ...[
                    _Caption('model_tools_confirm_before'.tr()),
                    _Value(change.before, muted: true),
                    const SizedBox(height: 10),
                    _Caption('model_tools_confirm_after'.tr()),
                  ],
                  _Value(change.after),
                ],
              ),
            if (proposal.lorebookEntryCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.menu_book_outlined,
                      size: 18,
                      color: context.cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'model_tools_confirm_lorebook'.plural(
                          proposal.lorebookEntryCount,
                          namedArgs: {
                            'name':
                                proposal.lorebookName ?? proposal.characterName,
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _preview(Object? value) => switch (value) {
    final List<dynamic> list => list.join(' · '),
    final Object other => other.toString().trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    ),
    null => '',
  };
}

/// The picture the card gets, next to the one it has when it already has
/// one.
class _AvatarChange extends StatelessWidget {
  const _AvatarChange({
    required this.after,
    required this.beforePath,
    required this.divider,
  });

  final Uint8List after;
  final String? beforePath;
  final bool divider;

  static const double _size = 96;

  @override
  Widget build(BuildContext context) {
    final before = beforePath;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: divider
            ? Border(bottom: BorderSide(color: context.cs.outlineVariant))
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('model_tools_field_avatar'.tr()),
            const SizedBox(height: 10),
            Row(
              children: [
                if (before != null && File(before).existsSync()) ...[
                  _frame(context, Image.file(File(before), fit: BoxFit.cover)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ],
                _frame(
                  context,
                  Image.memory(
                    after,
                    fit: BoxFit.cover,
                    errorBuilder: (context, _, _) => Icon(
                      Icons.broken_image_outlined,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _frame(BuildContext context, Widget image) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: SizedBox(
      width: _size,
      height: _size * 4 / 3,
      child: ColoredBox(color: context.inputFill, child: image),
    ),
  );
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: context.cs.primary,
      ),
    ),
  );
}

class _Value extends StatelessWidget {
  const _Value(this.value, {this.muted = false});

  final Object? value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 13,
      height: 1.35,
      color: muted ? context.cs.onSurfaceVariant : context.cs.onSurface,
    );
    final text = switch (value) {
      final List<dynamic> list when list.isEmpty => null,
      final List<dynamic> list => [
        for (final (i, item) in list.indexed) '${i + 1}. $item',
      ].join('\n\n'),
      final String s when s.trim().isEmpty => null,
      final Object other => other.toString(),
      null => null,
    };
    return SelectableText(
      text ?? 'model_tools_confirm_empty'.tr(),
      style: text == null ? style.copyWith(fontStyle: FontStyle.italic) : style,
    );
  }
}
