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
    // Text and placeholder share one style with a fixed line height, and the
    // field is collapsed (no decorator padding or suffix of its own), so the
    // single text line is centred by the row below exactly like the cross —
    // whatever the font's own metrics are.
    const lineStyle = TextStyle(fontSize: 14, height: 1.25);
    final field = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): search.closeSearch,
      },
      child: TextField(
        controller: search.searchController,
        autofocus: true,
        style: lineStyle.copyWith(color: context.cs.onSurface),
        strutStyle: StrutStyle.fromTextStyle(lineStyle, forceStrutHeight: true),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isCollapsed: true,
          contentPadding: EdgeInsets.zero,
          hintText: 'search_messages'.tr(),
          hintStyle: lineStyle.copyWith(
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          // The rounded box below is the background; the theme's fill and
          // borders on top would draw a second box inside it.
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
        // The id comes from the screen rather than the router: under the
        // title bar the field is built outside the chat route.
        onChanged: (q) => search.syncInlineQuery(
          q,
          ref.read(chatProvider(charId)).value?.messages ?? const [],
        ),
      ),
    );

    // The cross is part of the field's box, at its right edge — where the
    // search icon was.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.cs.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const SizedBox(width: 10),
          Expanded(child: field),
          _HeaderIconButton(
            icon: Icons.close_rounded,
            tooltip: 'btn_close'.tr(),
            onPressed: search.closeSearch,
          ),
          const SizedBox(width: 2),
        ],
      ),
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
