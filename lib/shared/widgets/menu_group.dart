import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform/haptics.dart';
import '../theme/app_colors.dart';
import '../shell/desktop/sidebar_sheet_provider.dart';
import '../shell/shell_header_provider.dart';
import 'glass_surface.dart';
import 'glow_ripple.dart';
import 'help_tip.dart';
import 'glaze_switch.dart';

enum MenuGroupHeaderVariant { standard, accentCaps }

/// Whether menu groups at [context] drop their cards and run flat: inside a
/// host that already frames them — a desktop window ([DetachedShellHost]'s
/// chrome) or a right-sidebar panel. A card there reads as a card inside a
/// card, so groups render as plain runs of rows with a rule under each.
bool menuGroupsFlat(BuildContext context) =>
    DetachedShellHost.drawsChrome(context) || inSidebarPanel(context);

// ── Collapsible section ────────────────────────────────────────────────────────

/// A disclosure header that hides a run of [MenuGroup]s until tapped.
///
/// Use it for settings that exist for troubleshooting or provider quirks
/// rather than day-to-day tuning: the screen stays readable for someone who
/// only needs an endpoint and a key, and the rest is one tap away. Collapsed
/// state is per-mount on purpose — reopening the screen starts tidy again.
///
/// Expanded, the header and what it reveals are **one** card. The header used
/// to be a card of its own with a 12 px gap under it, so opening a section
/// produced a floating strip above a stack of unrelated-looking groups and
/// nothing on screen said which rows belonged to it. Now the chevron is the
/// only thing that changes, the children render flat (see [MenuGroupNesting])
/// and the block simply grows downward.
class MenuCollapsibleSection extends StatefulWidget {
  final String label;
  final String? helpTerm;
  final List<Widget> children;

  /// Opens the section on mount — for one whose rows are already in use, so
  /// an active setting is never hidden behind the disclosure.
  final bool initiallyExpanded;

  const MenuCollapsibleSection({
    super.key,
    required this.label,
    this.helpTerm,
    required this.children,
    this.initiallyExpanded = false,
  });

  @override
  State<MenuCollapsibleSection> createState() => _MenuCollapsibleSectionState();
}

class _MenuCollapsibleSectionState extends State<MenuCollapsibleSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final flat = menuGroupsFlat(context);
    final radius = flat ? BorderRadius.zero : BorderRadius.circular(20);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          mouseCursor: SystemMouseCursors.click,
          // Only the top corners round while the section is open: the card
          // continues past the header into its own content.
          borderRadius: _expanded
              ? BorderRadius.vertical(top: radius.topLeft)
              : radius,
          onTap: () {
            Haptics.selectionClick();
            setState(() => _expanded = !_expanded);
          },
          child: _buildHeader(context),
        ),
        // The children are laid out inside this card, so they must not draw
        // cards of their own. The last one also drops its separator rule,
        // which would otherwise double up against the card's own edge.
        if (_expanded)
          for (var i = 0; i < widget.children.length; i++)
            MenuGroupNesting(
              showDivider: i < widget.children.length - 1,
              child: widget.children[i],
            ),
      ],
    );

    if (flat) return FlatGroupSurface(child: content);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GlassSurface(
        enableRipple: true,
        borderRadius: radius,
        border: Border.all(color: context.cs.outlineVariant),
        child: content,
      ),
    );
  }

  /// The header carries a top-to-bottom wash of the accent colour while the
  /// section is open, so the block reads as one thing with a lid rather than
  /// as a row that happens to sit above some rows.
  Widget _buildHeader(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: _expanded
              ? [
                  context.cs.primary.withValues(alpha: 0.22),
                  context.cs.primary.withValues(alpha: 0.0),
                ]
              : [
                  context.cs.primary.withValues(alpha: 0.0),
                  context.cs.primary.withValues(alpha: 0.0),
                ],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          // Expanded, not bare: a long or localized label used to push the
          // chevron off the row and overflow it. It takes the free space
          // itself rather than leaving it to a Spacer, which would compete
          // with it and ellipsise a label that had room.
          Expanded(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _expanded
                    ? context.cs.onSurface
                    : context.cs.onSurfaceVariant,
                fontSize: 16,
                fontWeight: _expanded ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          if (widget.helpTerm != null) HelpTip(term: widget.helpTerm!),
          AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 150),
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              color: _expanded
                  ? context.cs.primary
                  : context.cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// A group's surface inside a host that draws its own frame (see
/// [menuGroupsFlat]): the rule under it and the tap glow, but no glass. The
/// host's own fill is already under it, and a second tint over that marked
/// out a lighter band exactly as tall as the groups, with the bare host
/// showing below the last one.
///
/// Also the surface of a list card laid out flat in a sidebar panel, so a row
/// of the list and a group of a settings screen read the same there.
class FlatGroupSurface extends StatelessWidget {
  final Widget child;

  /// Fill under the content, for a row that marks itself out (the active
  /// one, say). Transparent by default.
  final Color? color;

  /// Bar down the leading edge, drawn over the content — what a card's accent
  /// border says when there is no card. It stays visible over a row that
  /// paints its own background (a cover image), where [color] would not.
  final Color? accent;

  const FlatGroupSurface({
    super.key,
    required this.child,
    this.color,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final accent = this.accent;
    return GlowRippleOverlay(
      glowColor: context.cs.primary,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          border: Border(bottom: BorderSide(color: context.cs.outlineVariant)),
        ),
        foregroundDecoration: accent == null || accent.a == 0
            ? null
            : BoxDecoration(
                border: Border(left: BorderSide(color: accent, width: 3)),
              ),
        // What a [GlassSurface] gives its content: a Material the rows' ink
        // lands on (the window's own sits under the screen's fill), and glass
        // inside that blurs on its own rather than joining the list's group.
        child: Material(
          type: MaterialType.transparency,
          child: GlassBackdropGroup.none(child: child),
        ),
      ),
    );
  }
}

/// Marks a subtree as living *inside* another card, so the [MenuGroup]s in it
/// drop their own surface, gutters and rounding and render as plain runs of
/// rows separated by a rule.
///
/// The same thing [DetachedShellHost] does for a screen hosted in the floating
/// window, scoped to one widget: a card drawn inside a card reads as a mistake
/// either way. The difference is that a nested group paints no glass of its
/// own — the enclosing card already did, and a second pass of tint and blur
/// over the same pixels only muddies them.
class MenuGroupNesting extends InheritedWidget {
  /// Whether a rule is drawn under this group. False for the last one in a
  /// section, where the card's own edge already closes the block.
  final bool showDivider;

  const MenuGroupNesting({
    super.key,
    this.showDivider = true,
    required super.child,
  });

  static MenuGroupNesting? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MenuGroupNesting>();

  @override
  bool updateShouldNotify(MenuGroupNesting oldWidget) =>
      oldWidget.showDivider != showDivider;
}

// ── Group container ────────────────────────────────────────────────────────────

class MenuGroup extends StatelessWidget {
  final String? header;
  final String? helpTerm;

  /// Optional muted hint rendered under the [header].
  final String? description;

  /// Optional widget pinned to the right edge of the header row (e.g. an
  /// enable/disable switch for the whole group).
  final Widget? headerTrailing;
  final List<Widget> items;
  final MenuGroupHeaderVariant headerVariant;
  final IconData? headerIcon;

  /// Arbitrary widget shown in place of [headerIcon], for a branded mark that
  /// cannot be expressed as an [IconData] (e.g. a source's SVG logo).
  final Widget? headerIconWidget;

  /// Kept for call-site compatibility; no longer affects visual style.
  // ignore: avoid_unused_constructor_parameters
  final bool compact;

  const MenuGroup({
    super.key,
    this.header,
    this.helpTerm,
    this.description,
    this.headerTrailing,
    required this.items,
    this.headerVariant = MenuGroupHeaderVariant.standard,
    this.headerIcon,
    this.headerIconWidget,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasItems = items.isNotEmpty;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (header != null) _buildHeader(context, hasItems: hasItems),
        ...items,
        // The trailing gap only separates the last row from the card's bottom
        // edge. An items-less group (the Catalog master switch, say) has no
        // row to separate from, and its header already carries the matching
        // bottom padding — the gap would only pad the hint's own line twice.
        if (hasItems) const SizedBox(height: 6),
      ],
    );

    // Inside an expanded [MenuCollapsibleSection] the section's own card is
    // already painted underneath, so the group contributes rows and a rule and
    // nothing else — no gutters, no rounding, and no second pane of glass.
    final nesting = MenuGroupNesting.of(context);
    if (nesting != null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          border: nesting.showDivider
              ? Border(bottom: BorderSide(color: context.cs.outlineVariant))
              : null,
        ),
        child: body,
      );
    }

    // Inside a window or a sidebar panel the host already draws a frame, so a
    // group that keeps its own card reads as a card inside a card. There it
    // runs edge to edge — no side gutters, no left/right edges, no rounding —
    // and only the rule under it separates one group from the next.
    if (menuGroupsFlat(context)) {
      return FlatGroupSurface(child: body);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GlassSurface(
        enableRipple: true,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.cs.outlineVariant),
        // A group card only ever has the static app background behind it (the
        // list itself does not paint anything under a card), so it can read the
        // once-baked backdrop texture instead of blurring per frame.
        backdropSample: true,
        child: body,
      ),
    );
  }

  Widget _buildHeader(BuildContext context, {required bool hasItems}) {
    final isAccentCaps = headerVariant == MenuGroupHeaderVariant.accentCaps;
    // With rows below, the header only needs a hairline gap before them, and
    // the hint sits tight under the title. Without rows the header *is* the
    // group, so it takes a full bottom pad to mirror the 16pt top — otherwise
    // the description ends up a few pixels from the card's edge.
    final bottomPad = hasItems ? (description != null ? 2.0 : 4.0) : 16.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 8, bottomPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (headerIconWidget != null) ...[
                      SizedBox(
                        width: isAccentCaps ? 16 : 18,
                        height: isAccentCaps ? 16 : 18,
                        child: Center(child: headerIconWidget),
                      ),
                      const SizedBox(width: 8),
                    ] else if (headerIcon != null) ...[
                      Icon(
                        headerIcon,
                        size: isAccentCaps ? 16 : 18,
                        color: context.cs.primary,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        isAccentCaps ? header!.toUpperCase() : header!,
                        style: TextStyle(
                          color: isAccentCaps
                              ? context.cs.primary
                              : context.cs.onSurface,
                          fontWeight: FontWeight.w700,
                          fontSize: isAccentCaps ? 13 : 18,
                          letterSpacing: isAccentCaps ? 0.3 : null,
                        ),
                      ),
                    ),
                    if (helpTerm != null) HelpTip(term: helpTerm!),
                  ],
                ),
              ),
              ?headerTrailing,
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                description!,
                style: const TextStyle(
                  color: Color(0xFF99A2AD),
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Sub-header ─────────────────────────────────────────────────────────────────

class MenuSubHeader extends StatelessWidget {
  final String label;

  const MenuSubHeader(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text(
        label,
        style: TextStyle(
          color: context.cs.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: 13,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

// ── Navigation item ────────────────────────────────────────────────────────────

class MenuItem extends StatefulWidget {
  final IconData? icon;
  final Widget? iconWidget;
  final String label;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback onTap;

  const MenuItem({
    super.key,
    this.icon,
    this.iconWidget,
    required this.label,
    this.subtitle,
    this.value,
    this.trailing,
    required this.onTap,
  });

  @override
  State<MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<MenuItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        Haptics.selectionClick();
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        color: _pressed
            ? context.cs.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            if (widget.iconWidget != null)
              SizedBox(width: 22, height: 22, child: widget.iconWidget)
            else if (widget.icon != null)
              Icon(widget.icon, size: 22, color: const Color(0xFF99A2AD)),
            if (widget.icon != null || widget.iconWidget != null)
              const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: context.cs.onSurfaceVariant,
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  if (widget.subtitle != null &&
                      widget.subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle!,
                      style: TextStyle(
                        color: context.cs.onSurfaceVariant.withValues(
                          alpha: 0.45,
                        ),
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (widget.value != null)
              Text(
                widget.value!,
                style: TextStyle(
                  color: context.cs.onSurfaceVariant,
                  fontSize: 14,
                ),
              ),
            if (widget.trailing != null) widget.trailing!,
            if (widget.value != null || widget.trailing != null)
              const SizedBox(width: 4),
          ],
        ),
      ),
    ));
  }
}

// ── Switch item ────────────────────────────────────────────────────────────────

class MenuSwitchItem extends StatelessWidget {
  final String label;
  final String? helpTerm;
  final String? description;
  final bool? included;
  final ValueChanged<bool>? onIncludedChanged;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// See [GlazeSwitch.activeColor].
  final Color? activeColor;

  const MenuSwitchItem({
    super.key,
    required this.label,
    this.helpTerm,
    this.description,
    this.included,
    this.onIncludedChanged,
    required this.value,
    required this.onChanged,
    this.activeColor,
  }) : assert(
         (included == null) == (onIncludedChanged == null),
         'included and onIncludedChanged must be provided together',
       );

  @override
  Widget build(BuildContext context) {
    return InkWell(
      mouseCursor: SystemMouseCursors.click,
      onTap: included ?? true
          ? () {
              Haptics.selectionClick();
              onChanged(!value);
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            if (included != null) ...[
              _ParameterIncludeSwitch(
                value: included!,
                onChanged: onIncludedChanged!,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          style: TextStyle(
                            color: context.cs.onSurfaceVariant,
                            fontSize: 16,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                      if (helpTerm != null) HelpTip(term: helpTerm!),
                    ],
                  ),
                  if (description != null) ...[
                    const SizedBox(height: 1),
                    Text(
                      description!,
                      style: const TextStyle(
                        color: Color(0xFF99A2AD),
                        fontSize: 12,
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            GlazeSwitch(
              value: value,
              onChanged: included ?? true ? onChanged : null,
              activeColor: activeColor,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Text field item ────────────────────────────────────────────────────────────

class MenuFieldItem extends StatelessWidget {
  final String label;
  final String? helpTerm;
  final TextEditingController controller;
  final String? placeholder;
  final bool obscure;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final int maxLines;

  /// Lines the field keeps even when empty; with a larger [maxLines] the
  /// field grows with its text up to that many lines before it scrolls.
  final int? minLines;
  final VoidCallback? onExpand;

  /// Muted hint under the label — for legends that would otherwise be crammed
  /// into the label itself.
  final String? description;

  /// Small caption *under* the field — used to show what a value resolves to
  /// (the endpoint field previews the URL that will actually be called).
  final String? helper;

  /// Renders [helper] as a warning instead of a neutral caption.
  final bool helperIsError;

  /// When non-null, a reset button is drawn to the left of the field and calls
  /// this to restore the default value. The caller passes it only while the
  /// field actually differs from that default.
  final VoidCallback? onReset;

  /// Stretches the input to the height this item is given, text starting at
  /// the top, instead of sizing it by its lines. Only for an item laid out
  /// with a bounded height (an [Expanded] one); [maxLines] and [minLines] are
  /// ignored then.
  final bool expands;

  /// Key placed on the internal [TextField] rather than on the item itself, so
  /// a caller (or a widget test) can address the editable widget directly.
  final Key? fieldKey;

  const MenuFieldItem({
    super.key,
    required this.label,
    this.helpTerm,
    required this.controller,
    this.placeholder,
    this.obscure = false,
    this.suffix,
    this.keyboardType,
    this.inputFormatters,
    this.onChanged,
    this.maxLines = 1,
    this.minLines,
    this.onExpand,
    this.description,
    this.helper,
    this.helperIsError = false,
    this.onReset,
    this.expands = false,
    this.fieldKey,
  });

  @override
  Widget build(BuildContext context) {
    final input = Row(
      crossAxisAlignment: expands
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.center,
      children: [
        if (onReset != null) ...[
          _ResetToDefaultButton(onPressed: onReset!),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: TextField(
            key: fieldKey,
            controller: controller,
            obscureText: obscure,
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            onChanged: onChanged,
            maxLines: expands ? null : maxLines,
            minLines: expands ? null : minLines,
            expands: expands,
            textAlignVertical: expands ? TextAlignVertical.top : null,
            style: TextStyle(color: context.cs.onSurface, fontSize: 15),
            decoration: InputDecoration(
              hintText: placeholder,
              hintStyle: TextStyle(
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.4),
              ),
              filled: true,
              fillColor: context.inputFill,
              suffixIcon: suffix,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: context.cs.outlineVariant),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: context.cs.outlineVariant),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: context.cs.primary.withValues(alpha: 0.5),
                  width: 1.5,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 13,
              ),
              isDense: true,
            ),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  color: context.cs.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
              if (helpTerm != null) HelpTip(term: helpTerm!, size: 14),
              const Spacer(),
              if (onExpand != null)
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onExpand,
                    child: Icon(
                      Icons.open_in_full,
                      size: 16,
                      color: context.cs.primary,
                    ),
                  ),
                ),
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 1),
            Text(
              description!,
              style: const TextStyle(
                color: Color(0xFF99A2AD),
                fontSize: 12,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
          const SizedBox(height: 6),
          if (expands) Expanded(child: input) else input,
          if (helper != null && helper!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              helper!,
              style: TextStyle(
                color: helperIsError
                    ? context.cs.error
                    : context.cs.onSurfaceVariant.withValues(alpha: 0.7),
                fontSize: 11.5,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Range slider item ──────────────────────────────────────────────────────────

class MenuRangeItem extends StatefulWidget {
  final String label;
  final String? helpTerm;

  /// Muted hint under the label — same role as [MenuFieldItem.description].
  final String? description;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final bool editableValue;
  final int decimalPlaces;

  /// Unit shown after the value — `%` on a percentage slider. Display only:
  /// the stored value stays a plain number.
  final String? unit;
  final bool? included;
  final ValueChanged<bool>? onIncludedChanged;
  final ValueChanged<double> onChanged;

  /// When non-null, a reset button is drawn to the left of the value field and
  /// calls this to restore the default. The caller passes it only while the
  /// parameter is enabled and its value actually differs from that default.
  final VoidCallback? onReset;

  const MenuRangeItem({
    super.key,
    required this.label,
    this.helpTerm,
    this.description,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions = 200,
    this.editableValue = false,
    this.decimalPlaces = 2,
    this.unit,
    this.included,
    this.onIncludedChanged,
    this.onReset,
  }) : assert(
         (included == null) == (onIncludedChanged == null),
         'included and onIncludedChanged must be provided together',
       );

  @override
  State<MenuRangeItem> createState() => _MenuRangeItemState();
}

class _MenuRangeItemState extends State<MenuRangeItem> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  bool get _included => widget.included ?? true;

  String get _display {
    if (widget.decimalPlaces == 0) return widget.value.round().toString();
    final s = widget.value.toStringAsFixed(widget.decimalPlaces);
    final trimmed = s.replaceAll(RegExp(r'0+$'), '');
    return trimmed.endsWith('.') ? '${trimmed}0' : trimmed;
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _display);
    _focusNode = FocusNode()..addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(MenuRangeItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && oldWidget.value != widget.value) {
      _controller.text = _display;
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!_focusNode.hasFocus) _commitInput();
  }

  void _commitInput() {
    final parsed = double.tryParse(_controller.text.replaceAll(',', '.'));
    if (parsed == null) {
      _controller.text = _display;
      return;
    }
    final value = parsed.clamp(widget.min, widget.max).toDouble();
    _controller.text = widget.decimalPlaces == 0
        ? value.round().toString()
        : value.toString();
    widget.onChanged(widget.decimalPlaces == 0 ? value.roundToDouble() : value);
  }

  void _handleSliderChanged(double value) {
    _controller.text = widget.decimalPlaces == 0
        ? value.round().toString()
        : value.toStringAsFixed(widget.decimalPlaces);
    widget.onChanged(value);
  }

  // Show/hide animation timing for the slider + value field when the parameter
  // is toggled on/off.
  static const Duration _toggleDuration = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    // When a parameter is toggled off it is not sent to the provider, so the
    // slider and number are hidden entirely — only the label + toggle remain.
    // The value itself is preserved by the parent and reappears when re-enabled.
    // The reveal/collapse is animated (size + fade) so the panel doesn't jump.
    return AnimatedPadding(
      duration: _toggleDuration,
      curve: Curves.easeInOut,
      padding: EdgeInsets.fromLTRB(16, 10, 16, _included ? 0 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (widget.included != null) ...[
                _ParameterIncludeSwitch(
                  value: widget.included!,
                  onChanged: widget.onIncludedChanged!,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.label,
                        style: TextStyle(
                          color: _included
                              ? context.cs.onSurface
                              : context.cs.onSurface.withValues(alpha: 0.4),
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (widget.helpTerm != null)
                      HelpTip(term: widget.helpTerm!, size: 14),
                  ],
                ),
              ),
              if (widget.onReset != null) ...[
                _ResetToDefaultButton(onPressed: widget.onReset!, size: 16),
                const SizedBox(width: 2),
              ],
              AnimatedCrossFade(
                duration: _toggleDuration,
                sizeCurve: Curves.easeInOut,
                firstCurve: Curves.easeOut,
                secondCurve: Curves.easeIn,
                alignment: Alignment.centerRight,
                crossFadeState: _included
                    ? CrossFadeState.showFirst
                    : CrossFadeState.showSecond,
                firstChild: _buildValueControl(context),
                secondChild: const SizedBox.shrink(),
              ),
            ],
          ),
          if (widget.description != null)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                widget.description!,
                style: const TextStyle(
                  color: Color(0xFF99A2AD),
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                ),
              ),
            ),
          AnimatedCrossFade(
            duration: _toggleDuration,
            sizeCurve: Curves.easeInOut,
            firstCurve: Curves.easeOut,
            secondCurve: Curves.easeIn,
            alignment: Alignment.topCenter,
            crossFadeState: _included
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: _buildSlider(context),
            secondChild: const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  /// The trailing editable number field (or a read-only value label).
  Widget _buildValueControl(BuildContext context) {
    if (widget.editableValue) {
      return SizedBox(
        width: widget.unit == null ? 72 : 88,
        height: 36,
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          enabled: _included,
          keyboardType: TextInputType.numberWithOptions(
            decimal: widget.decimalPlaces > 0,
            signed: widget.min < 0,
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(
              RegExp(widget.min < 0 ? r'[-0-9.,]' : r'[0-9.,]'),
            ),
          ],
          textAlign: TextAlign.center,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _commitInput(),
          style: TextStyle(
            color: context.cs.onSurface,
            fontSize: 14,
            fontVariations: const [FontVariation('wght', 500)],
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: context.inputFill,
            suffixText: widget.unit,
            suffixStyle: TextStyle(
              color: context.cs.onSurfaceVariant,
              fontSize: 13,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: context.cs.outlineVariant),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: context.cs.outlineVariant),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                color: context.cs.primary.withValues(alpha: 0.5),
                width: 1.5,
              ),
            ),
          ),
        ),
      );
    }
    return Text(
      widget.unit == null ? _display : '$_display${widget.unit}',
      style: TextStyle(
        color: context.cs.onSurfaceVariant,
        fontSize: 14,
        fontVariations: const [FontVariation('wght', 500)],
      ),
    );
  }

  /// The parameter slider itself.
  Widget _buildSlider(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: context.cs.primary,
        thumbColor: context.cs.primary,
        inactiveTrackColor: context.cs.primary.withValues(alpha: 0.18),
        overlayColor: context.cs.primary.withValues(alpha: 0.1),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      ),
      child: Slider(
        value: widget.value.clamp(widget.min, widget.max),
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        onChanged: _included ? _handleSliderChanged : null,
      ),
    );
  }
}

// ── Script list item ──────────────────────────────────────────────────────────

/// List item for named scripts (regex, lorebook, etc.) with a toggle switch
/// and a trailing more-vert action. Visual style matches [MenuItem].
class MenuScriptItem extends StatefulWidget {
  final String name;
  final String? subtitle;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const MenuScriptItem({
    super.key,
    required this.name,
    this.subtitle,
    required this.enabled,
    required this.onToggle,
    required this.onTap,
    required this.onMore,
  });

  @override
  State<MenuScriptItem> createState() => _MenuScriptItemState();
}

class _MenuScriptItemState extends State<MenuScriptItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        Haptics.selectionClick();
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        color: _pressed
            ? context.cs.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      color: widget.enabled
                          ? context.cs.onSurfaceVariant
                          : context.cs.onSurfaceVariant.withValues(alpha: 0.4),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (widget.subtitle != null &&
                      widget.subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.cs.onSurfaceVariant.withValues(
                          alpha: 0.45,
                        ),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch(
              value: widget.enabled,
              onChanged: (v) {
                Haptics.selectionClick();
                widget.onToggle(v);
              },
              activeThumbColor: context.cs.primary,
              activeTrackColor: context.cs.primary.withValues(alpha: 0.5),
              trackOutlineColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? Colors.transparent
                    : context.cs.outlineVariant,
              ),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                Haptics.selectionClick();
                widget.onMore();
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
                child: Icon(
                  Icons.more_vert,
                  size: 20,
                  color: context.cs.onSurfaceVariant.withValues(alpha: 0.45),
                ),
              ),
            )),
          ],
        ),
      ),
    ));
  }
}

// ── Selector item ──────────────────────────────────────────────────────────────

class MenuSelectorItem extends StatelessWidget {
  final String label;
  final String? helpTerm;
  final String currentValue;
  final bool? included;
  final ValueChanged<bool>? onIncludedChanged;
  final VoidCallback onTap;

  /// Muted hint under the label — same role as [MenuFieldItem.description].
  final String? description;

  /// When non-null, a reset button is drawn to the left of the selector and
  /// calls this to restore the default. The caller passes it only while the
  /// parameter is enabled and its value actually differs from that default.
  final VoidCallback? onReset;

  const MenuSelectorItem({
    super.key,
    required this.label,
    this.helpTerm,
    required this.currentValue,
    this.included,
    this.onIncludedChanged,
    required this.onTap,
    this.description,
    this.onReset,
  }) : assert(
         (included == null) == (onIncludedChanged == null),
         'included and onIncludedChanged must be provided together',
       );

  @override
  Widget build(BuildContext context) {
    final isIncluded = included ?? true;
    return InkWell(
      mouseCursor: SystemMouseCursors.click,
      onTap: isIncluded
          ? () {
              Haptics.selectionClick();
              onTap();
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (included != null) ...[
                  _ParameterIncludeSwitch(
                    value: included!,
                    onChanged: onIncludedChanged!,
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: isIncluded
                        ? context.cs.onSurfaceVariant
                        : context.cs.onSurfaceVariant.withValues(alpha: 0.4),
                    fontSize: 13,
                  ),
                ),
                if (helpTerm != null) HelpTip(term: helpTerm!, size: 14),
              ],
            ),
            if (description != null) ...[
              const SizedBox(height: 1),
              Text(
                description!,
                style: const TextStyle(
                  color: Color(0xFF99A2AD),
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                if (onReset != null) ...[
                  _ResetToDefaultButton(onPressed: onReset!),
                  const SizedBox(width: 6),
                ],
                // Same box as [MenuFieldItem]'s text field — fill, radius,
                // border and metrics. Without the outline a selector read as a
                // different kind of control from the fields it sits between.
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    constraints: const BoxConstraints(minHeight: 48),
                    decoration: BoxDecoration(
                      color: context.inputFill,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: context.cs.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            currentValue,
                            style: TextStyle(
                              color: isIncluded
                                  ? context.cs.onSurface
                                  : context.cs.onSurface.withValues(alpha: 0.4),
                              fontSize: 15,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: context.cs.onSurfaceVariant.withValues(
                            alpha: 0.5,
                          ),
                          size: 22,
                        ),
                      ],
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
}

/// Restores a single setting to its factory value.
///
/// Sits immediately left of the control it belongs to and is only built while
/// the current value differs from the default — the caller decides that and
/// passes [MenuFieldItem.onReset] / [MenuRangeItem.onReset] /
/// [MenuSelectorItem.onReset] only for the rows that can be reset.
class _ResetToDefaultButton extends StatelessWidget {
  final VoidCallback onPressed;
  final double size;

  const _ResetToDefaultButton({required this.onPressed, this.size = 18});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'reset_to_default'.tr(),
      child: InkResponse(
        mouseCursor: SystemMouseCursors.click,
        onTap: () {
          Haptics.selectionClick();
          onPressed();
        },
        radius: 18,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.undo_rounded,
            size: size,
            color: context.cs.primary,
          ),
        ),
      ),
    );
  }
}

class _ParameterIncludeSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ParameterIncludeSwitch({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      child: FittedBox(
        fit: BoxFit.contain,
        child: Switch(
          value: value,
          onChanged: (next) {
            Haptics.selectionClick();
            onChanged(next);
          },
          activeThumbColor: context.cs.primary,
          activeTrackColor: context.cs.primary.withValues(alpha: 0.5),
          trackOutlineColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? Colors.transparent
                : context.cs.outlineVariant,
          ),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}
