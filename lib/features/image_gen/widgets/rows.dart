import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../image_gen_models.dart';

/// Reusable form-row widgets used by the image generation settings
/// sheet. Extracted from image_gen_sheet.dart (which was 1091 lines
/// after the build flow grew four parallel api-type branches).
/// These rows are api-agnostic — they take a value, an onChange
/// callback, and render consistently across all branches.

class ImageGenMenuGroup extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final List<Widget> children;

  const ImageGenMenuGroup({
    super.key,
    required this.title,
    this.trailing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        ...children,
        const SizedBox(height: 16),
      ],
    );
  }
}

class ImageGenSelectorRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const ImageGenSelectorRow({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: context.cs.primary,
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 22,
                  color: context.cs.primary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ImageGenCheckboxRow extends StatelessWidget {
  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool> onChanged;

  const ImageGenCheckboxRow({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 14)),
                if (description != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      description!,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class ImageGenTextFieldItem extends StatefulWidget {
  final String label;
  final String value;
  final bool obscure;
  final String? hint;
  final ValueChanged<String> onChanged;
  final Widget? suffix;
  const ImageGenTextFieldItem({
    super.key,
    required this.label,
    required this.value,
    this.obscure = false,
    this.hint,
    required this.onChanged,
    this.suffix,
  });
  @override
  State<ImageGenTextFieldItem> createState() => _ImageGenTextFieldItemState();
}

class _ImageGenTextFieldItemState extends State<ImageGenTextFieldItem> {
  late final _controller = TextEditingController(text: widget.value);
  bool _obscure = true;

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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                obscureText: widget.obscure && _obscure,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: widget.hint,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  suffixIcon: widget.obscure
                      ? IconButton(
                          icon: Icon(
                            _obscure ? Icons.visibility_off : Icons.visibility,
                            size: 18,
                          ),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        )
                      : null,
                ),
                onChanged: widget.onChanged,
              ),
            ),
            if (widget.suffix != null) ...[
              const SizedBox(width: 8),
              widget.suffix!,
            ],
          ],
        ),
      ],
    ),
  );
}

class ImageGenReferenceRow extends StatefulWidget {
  final ReferenceImage refItem;
  final ValueChanged<String> onNameChanged;
  final ValueChanged<String> onMatchModeChanged;
  final VoidCallback onPickImage;
  final VoidCallback onRemove;

  const ImageGenReferenceRow({
    super.key,
    required this.refItem,
    required this.onNameChanged,
    required this.onMatchModeChanged,
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

  @override
  void didUpdateWidget(covariant ImageGenReferenceRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refItem.name != oldWidget.refItem.name &&
        widget.refItem.name != _controller.text) {
      _controller.text = widget.refItem.name;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          InkWell(
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
                      : Colors.black12,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: _referencePreview(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              onChanged: widget.onNameChanged,
              decoration: InputDecoration(
                hintText: '${'imggen_ref_keyword'.tr()} (Zoe, Зои)',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
                border: InputBorder.none,
              ),
            ),
          ),
          InkWell(
            onTap: () {
              showModalBottomSheet<void>(
                context: context,
                backgroundColor: Colors.transparent,
                builder: (context) => Container(
                  decoration: BoxDecoration(
                    color: context.cs.surface,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'imggen_match_mode'.tr(),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        ListTile(
                          title: Text('imggen_match_mode_match'.tr()),
                          trailing: widget.refItem.matchMode == 'match'
                              ? Text(
                                  'label_active'.tr(),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.cs.primary,
                                  ),
                                )
                              : null,
                          onTap: () {
                            widget.onMatchModeChanged('match');
                            Navigator.pop(context);
                          },
                        ),
                        ListTile(
                          title: Text('imggen_match_mode_always'.tr()),
                          trailing: widget.refItem.matchMode == 'always'
                              ? Text(
                                  'label_active'.tr(),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.cs.primary,
                                  ),
                                )
                              : null,
                          onTap: () {
                            widget.onMatchModeChanged('always');
                            Navigator.pop(context);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
            child: Row(
              children: [
                Text(
                  widget.refItem.matchMode.isEmpty
                      ? 'imggen_match_mode_match'.tr()
                      : widget.refItem.matchMode,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 18,
                  color: context.cs.primary,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: Colors.grey),
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
