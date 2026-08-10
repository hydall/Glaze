import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/platform/haptics.dart';
import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'help_tip.dart';

enum MenuGroupHeaderVariant { standard, accentCaps }

// ── Collapsible section ────────────────────────────────────────────────────────

/// A disclosure header that hides a run of [MenuGroup]s until tapped.
///
/// Use it for settings that exist for troubleshooting or provider quirks
/// rather than day-to-day tuning: the screen stays readable for someone who
/// only needs an endpoint and a key, and the rest is one tap away. Collapsed
/// state is per-mount on purpose — reopening the screen starts tidy again.
class MenuCollapsibleSection extends StatefulWidget {
  final String label;
  final String? helpTerm;
  final List<Widget> children;

  const MenuCollapsibleSection({
    super.key,
    required this.label,
    this.helpTerm,
    required this.children,
  });

  @override
  State<MenuCollapsibleSection> createState() => _MenuCollapsibleSectionState();
}

class _MenuCollapsibleSectionState extends State<MenuCollapsibleSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: GlassSurface(
            enableRipple: true,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: context.cs.outlineVariant),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                Haptics.selectionClick();
                setState(() => _expanded = !_expanded);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Text(
                      widget.label,
                      style: TextStyle(
                        color: context.cs.onSurfaceVariant,
                        fontSize: 16,
                      ),
                    ),
                    if (widget.helpTerm != null)
                      HelpTip(term: widget.helpTerm!),
                    const Spacer(),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_expanded) ...widget.children,
      ],
    );
  }
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
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GlassSurface(
        enableRipple: true,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.cs.outlineVariant),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (header != null) _buildHeader(context),
            ...items,
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final isAccentCaps = headerVariant == MenuGroupHeaderVariant.accentCaps;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 8, description != null ? 2 : 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (headerIcon != null) ...[
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
    return GestureDetector(
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
    );
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

  const MenuSwitchItem({
    super.key,
    required this.label,
    this.helpTerm,
    this.description,
    this.included,
    this.onIncludedChanged,
    required this.value,
    required this.onChanged,
  }) : assert(
         (included == null) == (onIncludedChanged == null),
         'included and onIncludedChanged must be provided together',
       );

  @override
  Widget build(BuildContext context) {
    return InkWell(
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
            Switch(
              value: value,
              onChanged: included ?? true
                  ? (v) {
                      Haptics.selectionClick();
                      onChanged(v);
                    }
                  : null,
              activeThumbColor: context.cs.primary,
              activeTrackColor: context.cs.primary.withValues(alpha: 0.5),
              trackOutlineColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? Colors.transparent
                    : context.cs.outlineVariant,
              ),
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
  final VoidCallback? onExpand;

  /// Muted hint under the label — for legends that would otherwise be crammed
  /// into the label itself.
  final String? description;

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
    this.onExpand,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
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
                GestureDetector(
                  onTap: onExpand,
                  child: Icon(
                    Icons.open_in_full,
                    size: 16,
                    color: context.cs.primary,
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
          TextField(
            controller: controller,
            obscureText: obscure,
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            onChanged: onChanged,
            maxLines: maxLines,
            style: TextStyle(color: context.cs.onSurface, fontSize: 15),
            decoration: InputDecoration(
              hintText: placeholder,
              hintStyle: TextStyle(
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.4),
              ),
              filled: true,
              fillColor: const Color(0xFF252525),
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
        ],
      ),
    );
  }
}

// ── Range slider item ──────────────────────────────────────────────────────────

class MenuRangeItem extends StatefulWidget {
  final String label;
  final String? helpTerm;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final bool editableValue;
  final int decimalPlaces;
  final bool? included;
  final ValueChanged<bool>? onIncludedChanged;
  final ValueChanged<double> onChanged;

  const MenuRangeItem({
    super.key,
    required this.label,
    this.helpTerm,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions = 200,
    this.editableValue = false,
    this.decimalPlaces = 2,
    this.included,
    this.onIncludedChanged,
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
        width: 72,
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
            fillColor: const Color(0xFF252525),
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
      _display,
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
    return GestureDetector(
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
            GestureDetector(
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
            ),
          ],
        ),
      ),
    );
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

  const MenuSelectorItem({
    super.key,
    required this.label,
    this.helpTerm,
    required this.currentValue,
    this.included,
    this.onIncludedChanged,
    required this.onTap,
    this.description,
  }) : assert(
         (included == null) == (onIncludedChanged == null),
         'included and onIncludedChanged must be provided together',
       );

  @override
  Widget build(BuildContext context) {
    final isIncluded = included ?? true;
    return InkWell(
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              height: 46,
              decoration: BoxDecoration(
                color: const Color(0xFF252525),
                borderRadius: BorderRadius.circular(12),
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
                    color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
                    size: 22,
                  ),
                ],
              ),
            ),
          ],
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
