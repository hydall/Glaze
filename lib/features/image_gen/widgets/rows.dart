import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_switch.dart';
import '../../../shared/widgets/glaze_text_field.dart';
import '../../../shared/widgets/menu_group.dart';
import '../image_gen_models.dart';

/// Image-gen specific rows.
///
/// Everything with a shared Glaze counterpart — group container, selector,
/// switch, text field — is built from `shared/widgets/menu_group.dart` at the
/// call site now. What is left here has no counterpart: the single-select
/// dropdown helper, the model-fetch suffix button, a controller-owning text
/// field wrapper (the field builders are plain functions and cannot own a
/// [TextEditingController]), and the reference-library row.

/// Single-select dropdown used by every image-gen picker.
///
/// Renders the shared [GlazeBottomSheet] list with a check mark on the current
/// value, so all image-gen dropdowns match the rest of the app.
void showImageGenOptions<T>(
  BuildContext context, {
  required String title,
  required List<T> items,
  required String Function(T) labelBuilder,
  required bool Function(T) isSelected,
  required void Function(T) onSelected,
}) {
  GlazeBottomSheet.show<void>(
    context,
    title: title,
    items: [
      for (final item in items)
        BottomSheetItem(
          label: labelBuilder(item),
          icon: isSelected(item) ? Icons.check : null,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            onSelected(item);
          },
        ),
    ],
  );
}

/// The two numeric fields shown when a size / resolution picker's "Custom"
/// entry is selected. An unparseable entry keeps the previous value, and the
/// result is clamped so a typo cannot ask a provider for a giant canvas.
List<Widget> imageGenCustomSizeFields({
  required int width,
  required int height,
  required ValueChanged<int> onWidthChanged,
  required ValueChanged<int> onHeightChanged,
}) {
  return [
    ImageGenTextFieldItem(
      label: 'imggen_width'.tr(),
      value: width.toString(),
      hint: '1024',
      onChanged: (v) => onWidthChanged(_clampSize(v, width)),
    ),
    ImageGenTextFieldItem(
      label: 'imggen_height'.tr(),
      value: height.toString(),
      hint: '1024',
      onChanged: (v) => onHeightChanged(_clampSize(v, height)),
    ),
  ];
}

int _clampSize(String raw, int fallback) {
  final parsed = int.tryParse(raw.trim());
  if (parsed == null) return fallback;
  return parsed.clamp(64, 8192);
}

/// Refresh button rendered as the suffix of a model field; shows a spinner
/// while the model list is being fetched.
class ImageGenFetchButton extends StatelessWidget {
  final bool isFetching;
  final VoidCallback onPressed;

  const ImageGenFetchButton({
    super.key,
    required this.isFetching,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (isFetching) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 18,
          height: 18,
          child: GlazeSpinner(),
        ),
      );
    }
    return IconButton(
      icon: Icon(Icons.refresh, size: 20, color: context.cs.onSurfaceVariant),
      tooltip: 'settings_fetch_models'.tr(),
      onPressed: onPressed,
    );
  }
}

/// [MenuFieldItem] that owns its controller, for the api-type field builders
/// which hand over a plain value + `onChanged` instead of a controller.
class ImageGenTextFieldItem extends StatefulWidget {
  final String label;
  final String value;
  final bool obscure;
  final String? hint;
  final ValueChanged<String> onChanged;
  final Widget? suffix;

  /// Shows a clear button while the field has content. Tapping it opens a
  /// confirmation sheet and wipes the whole field when confirmed.
  final bool clearable;

  const ImageGenTextFieldItem({
    super.key,
    required this.label,
    required this.value,
    this.obscure = false,
    this.hint,
    required this.onChanged,
    this.suffix,
    this.clearable = false,
  });

  @override
  State<ImageGenTextFieldItem> createState() => _ImageGenTextFieldItemState();
}

class _ImageGenTextFieldItemState extends State<ImageGenTextFieldItem> {
  late final _controller = TextEditingController(text: widget.value);
  bool _obscured = true;

  @override
  void didUpdateWidget(covariant ImageGenTextFieldItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MenuFieldItem(
      label: widget.label,
      controller: _controller,
      placeholder: widget.hint,
      obscure: widget.obscure && _obscured,
      onChanged: widget.onChanged,
      suffix: _suffix(context),
    );
  }

  Widget? _suffix(BuildContext context) {
    if (widget.suffix != null) return widget.suffix;
    if (widget.obscure) return _revealButton(context);
    if (widget.clearable && widget.value.isNotEmpty) return _clearButton(context);
    return null;
  }

  Widget _clearButton(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.close, size: 18, color: context.cs.onSurfaceVariant),
      tooltip: 'common_clear'.tr(),
      onPressed: _confirmClear,
    );
  }

  Future<void> _confirmClear() async {
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'imggen_negative_clear_title'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'imggen_negative_clear_desc'.tr(),
      ),
      items: [
        BottomSheetItem(
          icon: Icons.clear,
          label: 'common_clear'.tr(),
          isDestructive: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          icon: Icons.close,
          label: 'common_cancel'.tr(),
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    if (confirmed != true) return;
    _controller.clear();
    widget.onChanged('');
  }

  Widget _revealButton(BuildContext context) {
    return IconButton(
      icon: Icon(
        _obscured
            ? Icons.visibility_outlined
            : Icons.visibility_off_outlined,
        size: 20,
        color: context.cs.onSurfaceVariant,
      ),
      onPressed: () => setState(() => _obscured = !_obscured),
    );
  }
}

class ImageGenReferenceRow extends StatefulWidget {
  final ReferenceImage refItem;
  final ValueChanged<String> onNameChanged;
  final ValueChanged<String> onDescriptionChanged;
  final ValueChanged<String> onMatchModeChanged;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onPickImage;
  final VoidCallback onRemove;

  const ImageGenReferenceRow({
    super.key,
    required this.refItem,
    required this.onNameChanged,
    required this.onDescriptionChanged,
    required this.onMatchModeChanged,
    required this.onEnabledChanged,
    required this.onPickImage,
    required this.onRemove,
  });

  @override
  State<ImageGenReferenceRow> createState() => _ImageGenReferenceRowState();
}

class _ImageGenReferenceRowState extends State<ImageGenReferenceRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.refItem.name,
  );
  late final TextEditingController _descriptionController =
      TextEditingController(text: widget.refItem.description);

  @override
  void didUpdateWidget(covariant ImageGenReferenceRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refItem.name != oldWidget.refItem.name &&
        widget.refItem.name != _controller.text) {
      _controller.text = widget.refItem.name;
    }
    if (widget.refItem.description != oldWidget.refItem.description &&
        widget.refItem.description != _descriptionController.text) {
      _descriptionController.text = widget.refItem.description;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(children: [_topRow(context), _descriptionField(context)]),
    );
  }

  Widget _descriptionField(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 48, bottom: 4),
      child: GlazeTextField(
        controller: _descriptionController,
        onChanged: widget.onDescriptionChanged,
        hint: 'imggen_ref_description_hint'.tr(),
        isDense: true,
      ),
    );
  }

  void _openMatchModePicker(BuildContext context) {
    showImageGenOptions<String>(
      context,
      title: 'imggen_match_mode'.tr(),
      items: const ['match', 'always'],
      labelBuilder: (mode) => mode == 'always'
          ? 'imggen_match_mode_always'.tr()
          : 'imggen_match_mode_match'.tr(),
      isSelected: (mode) =>
          (widget.refItem.matchMode.isEmpty ? 'match' : widget.refItem.matchMode) ==
          mode,
      onSelected: widget.onMatchModeChanged,
    );
  }

  Widget _topRow(BuildContext context) {
    return Opacity(
      opacity: widget.refItem.enabled ? 1 : 0.5,
      child: Row(
        children: [
          InkWell(
            mouseCursor: SystemMouseCursors.click,
            onTap: widget.onPickImage,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: context.cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: widget.refItem.imageData.isNotEmpty
                      ? context.cs.primary
                      : context.cs.outlineVariant,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: _referencePreview(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GlazeTextField(
              controller: _controller,
              onChanged: widget.onNameChanged,
              hint: '${'imggen_ref_keyword'.tr()} (Zoe, Зои)',
              isDense: true,
            ),
          ),
          InkWell(
            mouseCursor: SystemMouseCursors.click,
            onTap: () => _openMatchModePicker(context),
            child: Row(
              children: [
                Text(
                  widget.refItem.matchMode == 'always'
                      ? 'imggen_match_mode_always'.tr()
                      : 'imggen_match_mode_match'.tr(),
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: context.cs.primary,
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          GlazeSwitch(
            value: widget.refItem.enabled,
            onChanged: widget.onEnabledChanged,
          ),
          IconButton(
            icon: Icon(
              Icons.close,
              size: 18,
              color: context.cs.onSurfaceVariant,
            ),
            onPressed: widget.onRemove,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _referencePreview() {
    final comma = widget.refItem.imageData.indexOf(',');
    if (comma < 0) {
      return const Icon(Icons.add_photo_alternate_outlined, size: 20);
    }
    try {
      return Image.memory(
        base64Decode(widget.refItem.imageData.substring(comma + 1)),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            const Icon(Icons.broken_image_outlined, size: 20),
      );
    } catch (_) {
      return const Icon(Icons.broken_image_outlined, size: 20);
    }
  }
}
