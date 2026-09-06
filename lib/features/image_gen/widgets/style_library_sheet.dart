import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/services/file_export_service.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../image_gen_models.dart';
import '../services/image_style_io.dart';

/// Style library: a list of named prompt styles plus the "no style" entry that
/// hands control back to the style written into the image tag by the model.
///
/// The list follows the Triggered Items card language — one card per style,
/// tap to make it active, three-dot menu for edit / export / delete — and the
/// header's `+` creates a new style and opens it in the editor. Styles can be
/// exported to and imported from JSON so they can be shared.
class StyleLibrarySheet extends StatefulWidget {
  const StyleLibrarySheet({
    super.key,
    required this.settings,
    required this.onUpdate,
  });

  final ImageGenSettings settings;
  final ValueChanged<ImageGenSettings> onUpdate;

  @override
  State<StyleLibrarySheet> createState() => _StyleLibrarySheetState();
}

class _StyleLibrarySheetState extends State<StyleLibrarySheet> {
  late ImageGenSettings _settings = widget.settings;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _valueController = TextEditingController();

  /// Id of the style open in the editor; empty means the list is showing.
  String _editingId = '';
  bool _isForward = true;

  @override
  void dispose() {
    _nameController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  /// Style open in the editor, or null when the list is showing (also when the
  /// edited style was deleted underneath us).
  ImageStyle? get _editing {
    for (final style in _settings.styles) {
      if (style.id == _editingId) return style;
    }
    return null;
  }

  void _update(ImageGenSettings next) {
    setState(() => _settings = next);
    widget.onUpdate(next);
  }

  // ── Navigation ──────────────────────────────────────────────────────────────

  /// Opens a style for editing. Controllers are owned by the state so typing
  /// does not reset the caret on rebuild.
  void _openEditor(ImageStyle style) {
    _nameController.text = style.name;
    _valueController.text = style.value;
    setState(() {
      _isForward = true;
      _editingId = style.id;
    });
  }

  void _closeEditor() {
    setState(() {
      _isForward = false;
      _editingId = '';
    });
  }

  // ── Style changes ───────────────────────────────────────────────────────────

  void _setActive(String id) =>
      _update(_settings.copyWith(activeStyleId: id));

  void _addStyle() {
    final style = ImageStyle(
      id: ImageStyleIo.newStyleId(),
      name: 'imggen_style_default_name'.tr(
        args: ['${_settings.styles.length + 1}'],
      ),
    );
    _update(_settings.copyWith(styles: [..._settings.styles, style]));
    _openEditor(style);
  }

  void _patchEditing(ImageStyle Function(ImageStyle) mutate) {
    final index = _settings.styles.indexWhere((s) => s.id == _editingId);
    if (index < 0) return;
    final copy = List<ImageStyle>.from(_settings.styles);
    copy[index] = mutate(copy[index]);
    _update(_settings.copyWith(styles: copy));
  }

  void _deleteStyle(ImageStyle style) {
    _update(
      _settings.copyWith(
        styles: _settings.styles.where((s) => s.id != style.id).toList(),
        activeStyleId: _settings.activeStyleId == style.id
            ? ''
            : _settings.activeStyleId,
      ),
    );
    if (_editingId == style.id) _closeEditor();
  }

  // ── Menus ────────────────────────────────────────────────────────────────────

  void _showStyleMenu(ImageStyle style) {
    GlazeBottomSheet.show<void>(
      context,
      title: style.name,
      items: [
        BottomSheetItem(
          icon: Icons.edit_outlined,
          label: 'action_edit'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _openEditor(style);
          },
        ),
        BottomSheetItem(
          icon: Icons.download_outlined,
          label: 'action_export'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _export([style], style.name);
          },
        ),
        BottomSheetItem(
          icon: Icons.delete_outline,
          iconColor: const Color(0xFFFF4444),
          label: 'action_delete'.tr(),
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _deleteStyle(style);
          },
        ),
      ],
    );
  }

  // ── Export / Import ──────────────────────────────────────────────────────────

  Future<void> _exportAll() async {
    if (_settings.styles.isEmpty) {
      GlazeToast.show(
        context,
        'imggen_styles_export_empty'.tr(),
        isError: true,
      );
      return;
    }
    await _export(_settings.styles, 'glaze_styles');
  }

  Future<void> _export(List<ImageStyle> styles, String title) async {
    try {
      final path = await FileExportService.export(
        data: ImageStyleIo.encode(styles),
        filename: ImageStyleIo.fileName(title),
        subfolder: 'styles',
      );
      if (path.isEmpty) return; // user cancelled the save dialog
      if (mounted) GlazeToast.show(context, 'imggen_styles_exported'.tr());
    } catch (error) {
      if (mounted) GlazeToast.show(context, '$error', isError: true);
    }
  }

  Future<void> _import() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    try {
      final bytes =
          picked.bytes ??
          (picked.path == null ? null : await File(picked.path!).readAsBytes());
      if (bytes == null) return;
      final imported = ImageStyleIo.decode(utf8.decode(bytes));
      _update(_settings.copyWith(styles: [..._settings.styles, ...imported]));
      if (mounted) {
        GlazeToast.show(
          context,
          'imggen_styles_imported'.tr(args: ['${imported.length}']),
        );
      }
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          '${'imggen_styles_import_failed'.tr()}: $error',
          isError: true,
        );
      }
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final editing = _editing;
    final isEditing = editing != null;

    return SheetView(
      title: isEditing ? editing.name : 'imggen_styles'.tr(),
      showBack: isEditing,
      onBack: _closeEditor,
      actions: isEditing
          ? const []
          : [
              SheetViewAction(
                icon: const Icon(Icons.file_download_outlined),
                tooltip: 'imggen_styles_import'.tr(),
                onPressed: _import,
              ),
              SheetViewAction(
                icon: const Icon(Icons.file_upload_outlined),
                tooltip: 'imggen_styles_export'.tr(),
                onPressed: _exportAll,
              ),
              SheetViewAction(
                icon: const Icon(Icons.add),
                tooltip: 'imggen_style_add'.tr(),
                onPressed: _addStyle,
              ),
            ],
      fitContent: false,
      enableHeaderBlur: false,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        transitionBuilder: _buildTransition,
        child: isEditing
            ? _buildEditor(context, editing)
            : _buildList(context),
      ),
    );
  }

  Widget _buildTransition(Widget child, Animation<double> animation) {
    final dir = _isForward ? 1.0 : -1.0;
    final isEntering = _isForward
        ? child.key != const ValueKey('style-list')
        : child.key == const ValueKey('style-list');
    return SlideTransition(
      position: Tween<Offset>(
        begin: isEntering ? Offset(dir * 0.06, 0) : Offset(-dir * 0.06, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: FadeTransition(opacity: animation, child: child),
    );
  }

  Widget _buildList(BuildContext context) {
    return Builder(
      key: const ValueKey('style-list'),
      builder: (context) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24).add(
          EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + 12,
            bottom: MediaQuery.paddingOf(context).bottom,
          ),
        ),
        children: [
          _StyleGroup(
            title: 'imggen_style_active'.tr(),
            cards: [
              _StyleCard(
                icon: Icons.block_outlined,
                name: 'imggen_style_none'.tr(),
                sublabel: 'imggen_style_none_desc'.tr(),
                active: _settings.activeStyleId.isEmpty,
                onTap: () => _setActive(''),
              ),
              for (final style in _settings.styles)
                _StyleCard(
                  icon: Icons.palette_outlined,
                  name: style.name,
                  sublabel: style.value.isEmpty
                      ? 'imggen_style_empty'.tr()
                      : style.value,
                  active: _settings.activeStyleId == style.id,
                  onTap: () => _setActive(style.id),
                  onMore: () => _showStyleMenu(style),
                ),
            ],
          ),
          if (_settings.styles.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text(
                  'imggen_styles_empty'.tr(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEditor(BuildContext context, ImageStyle style) {
    return ListView(
      key: ValueKey('style-edit-${style.id}'),
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 24).add(
        EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 12,
          bottom: MediaQuery.paddingOf(context).bottom,
        ),
      ),
      children: [
        MenuGroup(
          items: [
            MenuFieldItem(
              label: 'imggen_style_name'.tr(),
              controller: _nameController,
              onChanged: (v) => _patchEditing(
                (s) => s.copyWith(name: v.trim().isEmpty ? s.name : v),
              ),
            ),
            MenuFieldItem(
              label: 'imggen_style_value'.tr(),
              controller: _valueController,
              placeholder: 'masterpiece, cinematic lighting, painterly',
              maxLines: 6,
              onChanged: (v) => _patchEditing((s) => s.copyWith(value: v)),
            ),
          ],
        ),
        MenuGroup(
          items: [
            MenuItem(
              icon: Icons.download_outlined,
              label: 'action_export'.tr(),
              onTap: () => _export([style], style.name),
            ),
            MenuItem(
              iconWidget: const Icon(
                Icons.delete_outline,
                size: 22,
                color: Color(0xFFFF4444),
              ),
              label: 'imggen_style_delete'.tr(),
              onTap: () => _deleteStyle(style),
            ),
          ],
        ),
      ],
    );
  }
}

// ── List UI widgets ────────────────────────────────────────────────────────────

/// Section header above a run of [_StyleCard]s, matching the Triggered Items
/// sheet's small-caps group label.
class _StyleGroup extends StatelessWidget {
  final String title;
  final List<Widget> cards;

  const _StyleGroup({required this.title, required this.cards});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ),
        ...cards,
      ],
    );
  }
}

class _StyleCard extends StatelessWidget {
  final IconData icon;
  final String name;
  final String sublabel;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onMore;

  const _StyleCard({
    required this.icon,
    required this.name,
    required this.sublabel,
    required this.active,
    required this.onTap,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: active
            ? context.cs.primary.withValues(alpha: 0.1)
            : Colors.white.withValues(alpha: 0.06),
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: active
                    ? context.cs.primary.withValues(alpha: 0.45)
                    : Colors.white.withValues(alpha: 0.1),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: context.cs.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    active ? Icons.check : icon,
                    size: 18,
                    color: context.cs.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: context.cs.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (sublabel.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          sublabel,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.cs.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                if (onMore != null)
                  IconButton(
                    icon: Icon(
                      Icons.more_vert,
                      size: 20,
                      color: context.cs.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                    onPressed: onMore,
                  )
                else
                  const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
