import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../state/chat_drawer_editing_provider.dart';
import '../state/chat_drawer_tab.dart';
import 'drawer_panel_scaffold.dart';
import 'magic_drawer.dart';
import 'quick_replies_panel.dart';

/// The chat drawer: one panel, one entry point, two tabs.
///
/// Tools (the former Quick Access grid) and Actions (the former Quick Replies
/// grid) used to be two panels behind two separate buttons in the input bar,
/// which meant a user who never pressed the second button never learned the
/// second half existed. The tab strip states both names on screen the moment
/// the drawer opens.
///
/// This widget owns everything the two tabs share — the scaffold chrome, the
/// header and edit mode — so each tab body renders nothing but its own grid.
class ChatDrawerPanel extends ConsumerStatefulWidget {
  final String charId;

  final bool disableEffects;

  /// Hides the drawer. Null when the host keeps it permanently visible (the
  /// desktop right sidebar), which also makes the drag handle decorative.
  final VoidCallback? onClose;

  /// Scrolls the chat webview to a message id, for Ledger diagnostics.
  final Future<void> Function(String messageId)? onScrollToMessage;

  /// Runs before an Actions tap starts a generation; false aborts it.
  final Future<bool> Function()? beforeGeneration;

  /// See [DrawerPanelScaffold.showTopBorder].
  final bool showTopBorder;

  /// Lays both tabs out as a full-width list instead of a three-column grid,
  /// and drops the drag handle — the desktop right sidebar, where the drawer
  /// is a column that is always there rather than a sheet over the keyboard.
  /// Opening a card there shrinks the list to its icons, beside the card's
  /// screen (see [rail]).
  final bool listLayout;

  /// Shrinks the [listLayout] drawer to the Tools tab's icons alone, without
  /// the header — the desktop sidebar's strip, beside an open card's screen or
  /// as the whole collapsed sidebar. Toggled on a mounted drawer, so the list
  /// keeps its rows and its scroll and every icon stays where it was.
  final bool rail;

  const ChatDrawerPanel({
    super.key,
    required this.charId,
    this.onClose,
    this.disableEffects = false,
    this.onScrollToMessage,
    this.beforeGeneration,
    this.showTopBorder = true,
    this.listLayout = false,
    this.rail = false,
  });

  @override
  ConsumerState<ChatDrawerPanel> createState() => _ChatDrawerPanelState();
}

class _ChatDrawerPanelState extends ConsumerState<ChatDrawerPanel> {
  void _startEditing() {
    if (!ref.read(chatDrawerEditingProvider)) {
      ref.read(chatDrawerEditingProvider.notifier).state = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(chatDrawerTabProvider);
    // Edit mode spans both tabs *and* the composer's pinned row above them —
    // one pencil, one meaning — so it lives in a provider rather than here:
    // the row is a sibling of this panel, out of reach of local state.
    final editing = ref.watch(chatDrawerEditingProvider);
    final rail = widget.listLayout && widget.rail;

    return DrawerPanelScaffold(
      disableEffects: widget.disableEffects,
      onDismiss: widget.onClose,
      showTopBorder: widget.showTopBorder,
      showHandle: !widget.listLayout,
      // No room for the tabs in the strip. Their space stays empty, so the
      // icons below keep their place.
      header: rail
          ? null
          : _ChatDrawerHeader(
              activeIndex: tab.index,
              editing: editing,
              onTabChanged: (index) {
                ref.read(chatDrawerTabProvider.notifier).state =
                    ChatDrawerTab.values[index];
              },
              onToggleEditing: () =>
                  ref.read(chatDrawerEditingProvider.notifier).state = !editing,
            ),
      // IndexedStack, not a switcher that discards the hidden tab: Tools
      // computes prompt/token stats on build, and rebuilding it on every tab
      // flip would re-run that work for nothing.
      content: IndexedStack(
        // The strip is the Tools tab's: its cards are the ones that open a
        // screen beside it.
        index: rail ? ChatDrawerTab.tools.index : tab.index,
        sizing: StackFit.expand,
        children: [
          MagicDrawerPanel(
            charId: widget.charId,
            // The strip has nothing to edit, and its icons must still open.
            editing: editing && !rail,
            onEditingRequested: _startEditing,
            onClose: widget.onClose,
            onScrollToMessage: widget.onScrollToMessage,
            listLayout: widget.listLayout,
            iconOnly: rail,
          ),
          // Not built for the strip: never shown there, an IndexedStack would
          // still lay it out, and its rows do not fit a strip's width.
          if (!rail)
            QuickRepliesPanel(
              charId: widget.charId,
              editing: editing,
              onEditingRequested: _startEditing,
              onClose: widget.onClose,
              beforeGeneration: widget.beforeGeneration,
              listLayout: widget.listLayout,
            ),
        ],
      ),
    );
  }
}

/// Tab strip plus the edit toggle, occupying the header slot the panel title
/// used to hold. The strip *is* the title: two words a new user can read
/// beats one "Quick Access" they cannot, and it costs no extra height, which
/// matters in a drawer only as tall as the keyboard it replaces.
class _ChatDrawerHeader extends StatelessWidget {
  final int activeIndex;
  final bool editing;
  final ValueChanged<int> onTabChanged;
  final VoidCallback onToggleEditing;

  const _ChatDrawerHeader({
    required this.activeIndex,
    required this.editing,
    required this.onTabChanged,
    required this.onToggleEditing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Top inset clears the drag handle (y=8..12, see [kDrawerHandleTop])
      // instead of starting on its edge, which is what made the handle read as
      // a seam across the old full-width track.
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: GlazeTabBar(
              // Underline, not the app-default pill: this strip heads the
              // panel rather than sitting inside it, and a filled accent
              // segment outweighed every card it was introducing.
              style: GlazeTabBarStyle.underline,
              tabs: [
                GlazeTabItem(
                  label: 'drawer_tab_tools'.tr(),
                  icon: Icons.auto_awesome,
                ),
                GlazeTabItem(
                  label: 'drawer_tab_actions'.tr(),
                  icon: Icons.bolt,
                ),
              ],
              activeIndex: activeIndex,
              onChanged: onTabChanged,
            ),
          ),
          const SizedBox(width: 10),
          _EditToggle(editing: editing, onTap: onToggleEditing),
        ],
      ),
    );
  }
}

/// Icon-only edit toggle. The label it used to carry would have squeezed the
/// tab strip; the tooltip keeps the affordance for anyone who long-presses.
///
/// At rest it is a bare glyph — a permanent ring next to a container-less tab
/// strip would be the only outlined thing in the header. The ring appears only
/// while editing, so the state change is what draws it rather than decorating
/// both states equally.
class _EditToggle extends StatelessWidget {
  final bool editing;
  final VoidCallback onTap;

  const _EditToggle({required this.editing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = editing ? 'btn_ok'.tr() : 'action_edit'.tr();

    return Tooltip(
      message: label,
      preferBelow: false,
      child: Semantics(
        button: true,
        toggled: editing,
        label: label,
        child: MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: editing
                  ? context.cs.primary.withValues(alpha: 0.22)
                  : Colors.transparent,
              border: Border.all(
                color: editing
                    ? context.cs.primary.withValues(alpha: 0.38)
                    : Colors.transparent,
              ),
            ),
            child: Icon(
              editing ? Icons.check : Icons.edit_outlined,
              size: 18,
              color: editing
                  ? context.cs.primary
                  : context.cs.onSurface.withValues(alpha: 0.55),
            ),
          )),
        ),
      ),
    );
  }
}
