import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../core/utils/platform_paths.dart';
import '../shell/desktop/desktop_layout_provider.dart';
import '../shell/shell_header_provider.dart';
import '../theme/app_colors.dart';
import 'fullscreen_editor.dart';
import 'glaze_bottom_sheet.dart';
import 'glass_surface.dart';
import 'menu_group.dart';

/// Room an editor leaves under its last field, past the bottom inset: clear of
/// a phone's floating nav bar, but only a margin inside a desktop window, where
/// nothing sits under the content and a phone's clearance reads as a strange
/// empty band.
double editorTrailingGap(BuildContext context) =>
    DetachedShellHost.drawsChrome(context) ? 16 : 60;

class GenericEditorField {
  final String key;
  final String label;
  final String
  type; // 'text', 'number', 'tags', 'textarea', 'greeting_list', 'select', 'switch', 'info'
  final bool expandable;
  final String? helpTerm;
  final String? placeholder;
  final int? rows;
  final List<Map<String, dynamic>>?
  options; // [{'label': 'System', 'value': 'system'}]
  final String? text;
  final bool Function(Map<String, dynamic> item)? showIf;

  const GenericEditorField({
    required this.key,
    required this.label,
    this.type = 'text',
    this.expandable = false,
    this.helpTerm,
    this.placeholder,
    this.rows,
    this.options,
    this.text,
    this.showIf,
  });
}

class GenericEditorSection {
  final String? title;
  final List<GenericEditorField> fields;

  const GenericEditorSection({this.title, required this.fields});
}

class GenericEditor extends StatefulWidget {
  final Map<String, dynamic> item;
  final List<GenericEditorSection> config;
  final bool showAvatar;
  final String avatarField;

  /// Defaults to the localized `hint_change_avatar` when not supplied — it
  /// cannot be a constructor default because `.tr()` is not a constant.
  final String? avatarHint;
  final String avatarPlaceholder;
  final Future<void> Function()? onAvatarTap;
  final void Function(Map<String, dynamic> values) onChanged;
  final void Function(String field, int index)? onOpenFsEditor;

  // ignore: avoid_unused_constructor_parameters
  final bool useWindows;
  final bool scrollable;
  final void Function(Map<String, dynamic> values)? onSave;
  final Duration debounceDuration;
  final EdgeInsetsGeometry? padding;

  /// Key of a `textarea` that, in a scrollable editor on desktop, stretches to
  /// take whatever height the other fields leave — the prompt block's content
  /// in its own window, which otherwise ends in an empty band. The editor then
  /// scrolls as a whole once the fields stop fitting.
  final String? fillField;

  const GenericEditor({
    super.key,
    required this.item,
    required this.config,
    this.showAvatar = false,
    this.avatarField = 'avatarPath',
    this.avatarHint,
    this.avatarPlaceholder = '?',
    this.onAvatarTap,
    required this.onChanged,
    this.onOpenFsEditor,
    this.useWindows = true,
    this.scrollable = true,
    this.onSave,
    this.debounceDuration = const Duration(milliseconds: 1000),
    this.padding,
    this.fillField,
  });

  @override
  State<GenericEditor> createState() => _GenericEditorState();
}

class _GenericEditorState extends State<GenericEditor> {
  late Map<String, dynamic> _localItem;
  final Map<String, TextEditingController> _controllers = {};
  Timer? _saveTimer;
  bool _hasPendingSave = false;
  bool _syncingControllers = false;

  /// Whether the editor is laid out for desktop; refreshed every build.
  bool _desktop = false;

  /// Whether [GenericEditor.fillField] stretches in this build.
  bool _filling = false;

  @override
  void initState() {
    super.initState();
    _localItem = Map.from(widget.item);
    _initControllers();
  }

  @override
  void didUpdateWidget(GenericEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    bool changed = false;
    for (final k in widget.item.keys) {
      if (widget.item[k] != _localItem[k]) {
        _localItem[k] = widget.item[k];
        changed = true;
      }
    }
    if (changed) {
      _syncingControllers = true;
      try {
        for (final section in widget.config) {
          for (final field in section.fields) {
            if (field.type == 'text' ||
                field.type == 'textarea' ||
                field.type == 'number') {
              final val = _localItem[field.key]?.toString() ?? '';
              if (_controllers[field.key]?.text != val) {
                _controllers[field.key]?.text = val;
              }
            } else if (field.type == 'tags') {
              final val = _localItem[field.key];
              final strVal = (val is List) ? val.join(', ') : '';
              if (_controllers[field.key]?.text != strVal) {
                _controllers[field.key]?.text = strVal;
              }
            }
          }
        }
      } finally {
        _syncingControllers = false;
      }
    }
  }

  void _initControllers() {
    for (final section in widget.config) {
      for (final field in section.fields) {
        if (['text', 'number', 'textarea', 'tags'].contains(field.type)) {
          final val = _localItem[field.key];
          String strVal = '';
          if (field.type == 'tags' && val is List) {
            strVal = val.join(', ');
          } else if (val != null) {
            strVal = val.toString();
          }
          final ctrl = TextEditingController(text: strVal);
          ctrl.addListener(() {
            _updateField(field.key, field.type, ctrl.text);
          });
          _controllers[field.key] = ctrl;
        }
      }
    }
  }

  void _updateField(String key, String type, String text) {
    if (_syncingControllers) return;
    if (type == 'number') {
      _localItem[key] = num.tryParse(text) ?? _localItem[key];
    } else if (type == 'tags') {
      _localItem[key] = text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    } else {
      _localItem[key] = text;
    }
    widget.onChanged(_localItem);
    _scheduleSave();
  }

  void _scheduleSave() {
    if (widget.onSave == null) return;
    _hasPendingSave = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(widget.debounceDuration, () {
      _hasPendingSave = false;
      widget.onSave!(_localItem);
    });
  }

  @override
  void dispose() {
    for (final ctrl in _controllers.values) {
      ctrl.dispose();
    }
    if (_hasPendingSave) {
      _saveTimer?.cancel();
      widget.onSave?.call(_localItem);
    }
    super.dispose();
  }

  // ── Greetings ──────────────────────────────────────────────────────────────────

  List<String> get _allGreetings {
    final list = <String>[];
    list.add((_localItem['first_mes'] as String?) ?? '');
    final alt = _localItem['alternate_greetings'];
    if (alt is List) list.addAll(alt.cast<String>());
    return list;
  }

  void _addGreeting() {
    if (_localItem['alternate_greetings'] == null) {
      _localItem['alternate_greetings'] = <String>[];
    }
    final alt = _localItem['alternate_greetings'] as List;
    alt.add('');
    widget.onChanged(_localItem);
    _scheduleSave();
    setState(() {});
    _openGreetingEditor(alt.length);
  }

  void _confirmDeleteGreeting(int index) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'confirm_delete_greeting'.tr(),
      items: [
        BottomSheetItem(
          label: 'btn_yes'.tr(),
          icon: Icons.check,
          iconColor: const Color(0xFFFF4444),
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _performDeleteGreeting(index);
          },
        ),
        BottomSheetItem(
          label: 'btn_no'.tr(),
          icon: Icons.close,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  void _performDeleteGreeting(int index) {
    if (index == 0) {
      final alt = _localItem['alternate_greetings'];
      if (alt is List && alt.isNotEmpty) {
        _localItem['first_mes'] = alt.removeAt(0);
      } else {
        _localItem['first_mes'] = '';
      }
    } else {
      final altIndex = index - 1;
      final alt = _localItem['alternate_greetings'];
      if (alt is List && alt.length > altIndex) alt.removeAt(altIndex);
    }
    widget.onChanged(_localItem);
    _scheduleSave();
    setState(() {});
  }

  // ── Selectors ──────────────────────────────────────────────────────────────────

  void _selectOption(GenericEditorField field, Object? value) {
    _localItem[field.key] = value;
    widget.onChanged(_localItem);
    _scheduleSave();
    setState(() {});
  }

  /// Picks a value for a `select` field: a dropdown anchored to the field on
  /// desktop, a bottom sheet on phones.
  void _openSelectSelector(GenericEditorField field, BuildContext anchor) {
    final options = field.options ?? const <Map<String, dynamic>>[];
    final currentVal = _localItem[field.key];
    String labelOf(Map<String, dynamic> opt) =>
        opt['label'] as String? ?? opt['value'].toString();

    if (isDesktopLayout(context)) {
      final box = anchor.findRenderObject() as RenderBox?;
      final overlay =
          Overlay.of(context).context.findRenderObject() as RenderBox?;
      if (box == null || overlay == null) return;
      // Anchored under the field's input box: the row's bottom edge minus
      // its bottom padding, spanning the input's width (the row's 16px side
      // gutters trimmed off).
      final topLeft = box.localToGlobal(
        Offset(16, box.size.height - 8),
        ancestor: overlay,
      );
      final width = box.size.width - 32;
      showMenu<Object?>(
        context: context,
        position: RelativeRect.fromLTRB(
          topLeft.dx,
          topLeft.dy + 4,
          overlay.size.width - topLeft.dx - width,
          0,
        ),
        constraints: BoxConstraints(minWidth: width, maxWidth: width),
        color: context.cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.cs.outlineVariant),
        ),
        items: [
          for (final opt in options)
            PopupMenuItem<Object?>(
              value: opt['value'],
              height: 40,
              child: Row(
                children: [
                  Expanded(child: Text(labelOf(opt))),
                  if (currentVal == opt['value'])
                    Icon(Icons.check, size: 18, color: context.cs.primary),
                ],
              ),
            ),
        ],
      ).then((value) {
        // A dismissed menu yields null, which is also a legal option value;
        // only treat it as a choice when some option really is null.
        if (!mounted) return;
        if (value == null && !options.any((o) => o['value'] == null)) return;
        _selectOption(field, value);
      });
      return;
    }

    GlazeBottomSheet.show<void>(
      context,
      title: field.label,
      items: [
        for (final opt in options)
          BottomSheetItem(
            label: labelOf(opt),
            icon: currentVal == opt['value'] ? Icons.check : null,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _selectOption(field, opt['value']);
            },
          ),
      ],
    );
  }

  String _getSelectedLabel(GenericEditorField field) {
    final val = _localItem[field.key];
    final opt = field.options?.firstWhere(
      (o) => o['value'] == val,
      orElse: () => {},
    );
    return (opt?['label'] as String?) ?? val?.toString() ?? '';
  }

  Future<void> _openFieldEditor(GenericEditorField field) async {
    if (widget.onOpenFsEditor != null) {
      widget.onOpenFsEditor!(field.key, -1);
      return;
    }

    final ctrl = _controllers[field.key];
    if (ctrl == null) return;

    await FullscreenEditorScreen.show(
      context,
      title: field.label,
      initialValue: ctrl.text,
      hintText: field.placeholder,
      onChanged: (value) {
        if (!mounted) return;
        // No setState: the field below the overlay is driven by this
        // controller and repaints from it on its own. The rebuild this used to
        // force ran the whole form again on every character typed in the
        // expanded editor, on top of the parent rebuild the change already
        // causes.
        ctrl.text = value;
      },
    );
  }

  Future<void> _openGreetingEditor(int index) async {
    if (widget.onOpenFsEditor != null) {
      widget.onOpenFsEditor!('first_mes', index);
      return;
    }

    final greetings = _allGreetings;
    if (index < 0 || index >= greetings.length) return;

    void applyGreeting(String value) {
      if (!mounted) return;
      if (index == 0) {
        _localItem['first_mes'] = value;
      } else {
        final alt =
            ((_localItem['alternate_greetings'] as List?) ?? <dynamic>[])
                .cast<String>()
                .toList();
        if (index - 1 >= alt.length) return;
        alt[index - 1] = value;
        _localItem['alternate_greetings'] = alt;
      }
      widget.onChanged(_localItem);
      _scheduleSave();
      if (mounted) setState(() {});
    }

    await FullscreenEditorScreen.show(
      context,
      title: 'generic_editor_greeting_title'.tr(args: ['${index + 1}']),
      initialValue: greetings[index],
      hintText: 'generic_editor_greeting_hint'.tr(),
      onChanged: applyGreeting,
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────────

  /// Width from which a scrollable editor switches to its desktop layout: the
  /// avatar in a column of its own beside the fields, and the fields held to
  /// a readable width instead of stretching across the whole window.
  static const double _wideBreakpoint = 720;

  /// Width of the avatar column in the wide layout.
  static const double _avatarPaneWidth = 300;

  /// Widest the field column grows in the wide layout.
  static const double _fieldsMaxWidth = 760;

  /// Largest the avatar card gets on a narrow desktop panel (the right sidebar,
  /// a sheet window), where the phone's full-width square would dwarf the
  /// fields.
  static const double _narrowDesktopAvatarMax = 320;

  @override
  Widget build(BuildContext context) {
    _desktop = isDesktopLayout(context);
    _filling =
        widget.fillField != null &&
        widget.scrollable &&
        _desktop &&
        !widget.showAvatar;
    final sections = [
      for (final section in widget.config) _buildSection(section),
    ];

    if (!widget.scrollable) {
      return Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: widget.padding ?? EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.showAvatar) _buildAvatarCard(),
              ...sections,
            ],
          ),
        ),
      );
    }

    final padding =
        widget.padding?.resolve(Directionality.of(context)) ??
        EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 16,
          bottom:
              MediaQuery.of(context).padding.bottom +
              editorTrailingGap(context),
        );

    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          if (_filling) {
            final gutter = width < _wideBreakpoint
                ? 0.0
                : ((width - _fieldsMaxWidth) / 2).clamp(0.0, double.infinity);
            return _buildFilling(
              constraints.maxHeight,
              padding.copyWith(
                left: padding.left + gutter,
                right: padding.right + gutter,
              ),
              sections,
            );
          }
          if (!_desktop || width < _wideBreakpoint) {
            return ListView(
              padding: padding,
              children: [
                if (widget.showAvatar) _buildAvatarCard(),
                ...sections,
              ],
            );
          }
          return _buildWide(width, padding, sections);
        },
      ),
    );
  }

  /// The fields in a column at least as tall as the viewport, the section
  /// holding [GenericEditor.fillField] taking up the slack; taller than that,
  /// it scrolls like the list it replaces.
  Widget _buildFilling(
    double viewport,
    EdgeInsets padding,
    List<Widget> sections,
  ) {
    return SingleChildScrollView(
      padding: padding,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: (viewport - padding.vertical).clamp(0.0, double.infinity),
        ),
        child: IntrinsicHeight(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: sections,
          ),
        ),
      ),
    );
  }

  /// Desktop layout: fields centered at a readable width; with an avatar, the
  /// avatar stays pinned in a column on the left while the fields scroll.
  ///
  /// The field list still spans to the right edge, so its scrollbar and the
  /// mouse wheel work from anywhere on that side, not just over the fields.
  Widget _buildWide(
    double width,
    EdgeInsets padding,
    List<Widget> sections,
  ) {
    final contentWidth = widget.showAvatar
        ? _avatarPaneWidth + _fieldsMaxWidth
        : _fieldsMaxWidth;
    final gutter = ((width - contentWidth) / 2).clamp(0.0, double.infinity);

    if (!widget.showAvatar) {
      return ListView(
        padding: padding.copyWith(
          left: padding.left + gutter,
          right: padding.right + gutter,
        ),
        children: sections,
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: gutter + padding.left),
        SizedBox(
          width: _avatarPaneWidth,
          child: SingleChildScrollView(
            padding: EdgeInsets.only(top: padding.top, bottom: padding.bottom),
            child: _buildAvatarCard(),
          ),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.only(
              top: padding.top,
              bottom: padding.bottom,
              right: gutter + padding.right,
            ),
            children: sections,
          ),
        ),
      ],
    );
  }

  Widget _buildSection(GenericEditorSection section) {
    final visibleFields = section.fields
        .where((f) => f.showIf == null || f.showIf!(_localItem))
        .toList();
    if (visibleFields.isEmpty) return const SizedBox.shrink();
    bool fills(GenericEditorField field) =>
        _filling && field.key == widget.fillField;
    final group = MenuGroup(
      header: section.title,
      headerVariant: MenuGroupHeaderVariant.accentCaps,
      items: [
        for (final field in visibleFields)
          fills(field)
              ? Expanded(child: _buildFieldItem(field))
              : _buildFieldItem(field),
      ],
    );
    return visibleFields.any(fills) ? Expanded(child: group) : group;
  }

  Widget _buildFieldItem(GenericEditorField field) {
    if (field.showIf != null && !field.showIf!(_localItem)) {
      return const SizedBox.shrink();
    }
    switch (field.type) {
      case 'text':
      case 'number':
      case 'tags':
      case 'textarea':
        final ctrl = _controllers[field.key];
        if (ctrl == null) return const SizedBox.shrink();
        final isArea = field.type == 'textarea';
        final rows = field.rows ?? 3;
        return MenuFieldItem(
          label: field.label,
          helpTerm: field.helpTerm,
          controller: ctrl,
          placeholder: field.placeholder,
          keyboardType: field.type == 'number'
              ? TextInputType.number
              : isArea
              ? TextInputType.multiline
              : TextInputType.text,
          // On desktop a text area starts at its configured height and grows
          // with its text, the way a web form's auto-sizing textarea does —
          // with a mouse and a tall window, scrolling inside a three-line box
          // is the phone compromise.
          maxLines: isArea ? (_desktop ? rows * 4 : rows) : 1,
          minLines: isArea && _desktop ? rows : null,
          expands: isArea && _filling && field.key == widget.fillField,
          onExpand: field.expandable ? () => _openFieldEditor(field) : null,
        );
      case 'select':
        return Builder(
          builder: (anchor) => MenuSelectorItem(
            label: field.label,
            helpTerm: field.helpTerm,
            currentValue: _getSelectedLabel(field),
            onTap: () => _openSelectSelector(field, anchor),
          ),
        );
      case 'switch':
        return MenuSwitchItem(
          label: field.label,
          helpTerm: field.helpTerm,
          value: _localItem[field.key] as bool? ?? false,
          onChanged: (value) {
            setState(() => _localItem[field.key] = value);
            widget.onChanged(_localItem);
            _scheduleSave();
          },
        );
      case 'greeting_list':
        return _buildGreetingItems();
      case 'info':
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            field.text ?? _localItem[field.key]?.toString() ?? '',
            style: TextStyle(
              color: context.cs.onSurfaceVariant,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildGreetingItems() {
    final greets = _allGreetings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < greets.length; i++)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _GreetingCard(
              index: i,
              text: greets[i],
              maxLines: _desktop ? 5 : 3,
              onEdit: () => _openGreetingEditor(i),
              onDelete: () => _confirmDeleteGreeting(i),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Material(
            color: context.cs.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _addGreeting,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add, size: 20, color: context.cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      'action_add_greeting'.tr(),
                      style: TextStyle(
                        color: context.cs.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAvatarCard() {
    final avatarPath = _localItem[widget.avatarField] as String?;
    final card = Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: GlassSurface(
        onTap: widget.onAvatarTap,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.cs.outlineVariant),
        child: Stack(
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                color: context.cs.surfaceContainerHighest,
                child: avatarPath != null && avatarPath.isNotEmpty
                    ? Image.file(
                        File(resolveGlazeThumbnailPath(avatarPath)!),
                        fit: BoxFit.cover,
                      )
                    : Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              const Color(0xFF66CCFF),
                              context.cs.primary,
                            ],
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          widget.avatarPlaceholder.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 96,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black54, Colors.transparent],
                  ),
                ),
                child: Text(
                  'avatar'.tr(),
                  style: TextStyle(
                    color: Color(0xE6FFFFFF),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 30, 16, 20),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black54, Colors.transparent],
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  widget.avatarHint ?? 'hint_change_avatar'.tr(),
                  style: const TextStyle(
                    color: Color(0xE6FFFFFF),
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (!_desktop) return card;
    // Desktop: never wider than a portrait-sized card, whatever column it
    // lands in — the phone's full-width square turned into a poster on a
    // desktop panel.
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: _narrowDesktopAvatarMax + 32,
        ),
        child: card,
      ),
    );
  }
}

/// One greeting in a `greeting_list` field: its number, edit and delete
/// buttons, and a preview of its text that opens the editor when clicked.
class _GreetingCard extends StatelessWidget {
  final int index;
  final String text;
  final int maxLines;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _GreetingCard({
    required this.index,
    required this.text,
    required this.maxLines,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    const deleteColor = Color(0xFFFF4444);
    return Material(
      color: context.cs.outlineVariant.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: context.cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '#${index + 1}',
                      style: TextStyle(
                        fontSize: 13,
                        color: context.cs.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    color: context.cs.primary,
                    tooltip: 'action_edit'.tr(),
                    visualDensity: VisualDensity.compact,
                    onPressed: onEdit,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    color: deleteColor,
                    tooltip: 'action_delete'.tr(),
                    visualDensity: VisualDensity.compact,
                    onPressed: onDelete,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  text.isEmpty ? 'action_add_greeting'.tr() : text,
                  style: TextStyle(
                    fontSize: 14,
                    color: text.isEmpty
                        ? context.cs.onSurfaceVariant
                        : context.cs.onSurface.withValues(alpha: 0.9),
                    height: 1.4,
                  ),
                  maxLines: maxLines,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
