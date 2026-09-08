import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../core/utils/platform_paths.dart';
import '../theme/app_colors.dart';
import 'fullscreen_editor.dart';
import 'glaze_bottom_sheet.dart';
import 'glass_surface.dart';
import 'menu_group.dart';

class GenericEditorField {
  final String key;
  final String label;
  final String
  type; // 'text', 'number', 'tags', 'textarea', 'greeting_list', 'select', 'info'
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
  });

  @override
  State<GenericEditor> createState() => _GenericEditorState();
}

class _GenericEditorState extends State<GenericEditor> {
  late Map<String, dynamic> _localItem;
  final Map<String, TextEditingController> _controllers = {};
  Timer? _saveTimer;
  bool _hasPendingSave = false;

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

  void _openSelectSelector(GenericEditorField field) {
    final currentVal = _localItem[field.key];
    final items =
        field.options?.map((opt) {
          final isSelected = currentVal == opt['value'];
          return BottomSheetItem(
            label: opt['label'] as String? ?? opt['value'].toString(),
            icon: isSelected ? Icons.check : null,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _localItem[field.key] = opt['value'];
              widget.onChanged(_localItem);
              _scheduleSave();
              setState(() {});
            },
          );
        }).toList() ??
        [];
    GlazeBottomSheet.show<void>(context, title: field.label, items: items);
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
        ctrl.text = value;
        setState(() {});
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

  @override
  Widget build(BuildContext context) {
    final children = [
      if (widget.showAvatar) _buildAvatarCard(),
      for (final section in widget.config) _buildSection(section),
    ];

    if (widget.scrollable) {
      return Material(
        type: MaterialType.transparency,
        child: ListView(
          padding:
              widget.padding ??
              EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 16,
                bottom: MediaQuery.of(context).padding.bottom + 60,
              ),
          children: children,
        ),
      );
    }
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: widget.padding ?? EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  Widget _buildSection(GenericEditorSection section) {
    final visibleFields = section.fields
        .where((f) => f.showIf == null || f.showIf!(_localItem))
        .toList();
    if (visibleFields.isEmpty) return const SizedBox.shrink();
    return MenuGroup(
      header: section.title,
      headerVariant: MenuGroupHeaderVariant.accentCaps,
      items: visibleFields.map(_buildFieldItem).toList(),
    );
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
        return MenuFieldItem(
          label: field.label,
          helpTerm: field.helpTerm,
          controller: ctrl,
          placeholder: field.placeholder,
          keyboardType: field.type == 'number'
              ? TextInputType.number
              : field.type == 'textarea'
              ? TextInputType.multiline
              : TextInputType.text,
          maxLines: field.type == 'textarea' ? (field.rows ?? 3) : 1,
          onExpand: field.expandable ? () => _openFieldEditor(field) : null,
        );
      case 'select':
        return MenuSelectorItem(
          label: field.label,
          currentValue: _getSelectedLabel(field),
          onTap: () => _openSelectSelector(field),
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
            child: Container(
              decoration: BoxDecoration(
                color: context.cs.outlineVariant.withValues(alpha: 0.08),
                border: Border.all(color: context.cs.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '#${i + 1}',
                          style: TextStyle(
                            fontSize: 13,
                            color: context.cs.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Row(
                          children: [
                            GestureDetector(
                              onTap: () => _openGreetingEditor(i),
                              child: Icon(
                                Icons.edit_outlined,
                                size: 18,
                                color: context.cs.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            GestureDetector(
                              onTap: () => _confirmDeleteGreeting(i),
                              child: const Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: Color(0xFFFF4444),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () => _openGreetingEditor(i),
                      child: Text(
                        greets[i].isEmpty
                            ? 'action_add_greeting'.tr()
                            : greets[i],
                        style: TextStyle(
                          fontSize: 14,
                          color: context.cs.onSurface.withValues(alpha: 0.9),
                          height: 1.4,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: GestureDetector(
            onTap: _addGreeting,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.cs.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
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
      ],
    );
  }

  Widget _buildAvatarCard() {
    final avatarPath = _localItem[widget.avatarField] as String?;
    return Container(
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
                        File(resolveGlazeFilePath(avatarPath)!),
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
  }
}
