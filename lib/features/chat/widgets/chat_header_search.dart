import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../guides/guide_anchor.dart';
import '../chat_provider.dart';
import '../chat_search_delegate.dart';

/// The desktop chat header: the character block with a search icon right
/// after the session name. The icon swaps the whole block for a search field
/// and turns into a cross that closes it again.
///
/// Highlighting follows the query (see [ChatSearchDelegate.syncInlineQuery]);
/// the field being shown is [ChatSearchDelegate.inlineOpen].
class DesktopChatHeaderSearch extends ConsumerWidget {
  final ChatSearchDelegate search;
  final String charId;

  /// Builds the character block with the search toggle as its trailing slot.
  final Widget Function(Widget searchToggle) headerBuilder;

  /// Under the app's title bar the field sits in a small rounded box of fixed
  /// width, the way a window's search usually looks there.
  final bool inTitleBar;

  const DesktopChatHeaderSearch({
    super.key,
    required this.search,
    required this.charId,
    required this.headerBuilder,
    this.inTitleBar = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListenableBuilder(
      listenable: search,
      builder: (context, _) {
        final open = search.inlineOpen;
        // The character block stays laid out (just hidden) while the field is
        // open, so the field takes exactly its width and position — centred
        // under the title bar, left-aligned in the in-app header.
        final block = Stack(
          children: [
            Visibility(
              visible: !open,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: inTitleBar ? 30 : 36),
                child: headerBuilder(
                  GuideAnchor(
                    id: GuideIds.chatSearch,
                    child: _HeaderIconButton(
                      icon: Icons.search_rounded,
                      tooltip: 'search_messages'.tr(),
                      onPressed: search.openInline,
                    ),
                  ),
                ),
              ),
            ),
            if (open) Positioned.fill(child: _buildField(context, ref)),
          ],
        );
        return inTitleBar
            ? block
            : Align(alignment: Alignment.centerLeft, child: block);
      },
    );
  }

  Widget _buildField(BuildContext context, WidgetRef ref) {
    final field = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): search.closeSearch,
      },
      child: TextField(
        controller: search.searchController,
        autofocus: true,
        style: TextStyle(color: context.cs.onSurface, fontSize: 14),
        textInputAction: TextInputAction.search,
        // Keeps the text on the cross's centre line rather than the top.
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          // The rounded box below is the background; the theme's square fill
          // on top would leave only a ragged ring of it.
          filled: false,
          hintText: 'search_messages'.tr(),
          hintStyle: TextStyle(
            fontSize: 14,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 7,
          ),
          // The cross sits inside the field, at its right edge — where the
          // search icon was.
          suffixIcon: _HeaderIconButton(
            icon: Icons.close_rounded,
            tooltip: 'btn_close'.tr(),
            onPressed: search.closeSearch,
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 0,
          ),
        ),
        // The id comes from the screen rather than the router: under the
        // title bar the field is built outside the chat route.
        onChanged: (q) => search.syncInlineQuery(
          q,
          ref.read(chatProvider(charId)).value?.messages ?? const [],
        ),
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.cs.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SizedBox.expand(child: Center(child: field)),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      color: context.cs.primary,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      onPressed: onPressed,
    );
  }
}
