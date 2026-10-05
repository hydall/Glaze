import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import '../models/tts_types.dart';

/// Rows for a provider's declared settings. Providers describe their fields
/// (`TtsField`) and this draws them with the kit's menu rows, so no provider
/// ships UI of its own.
List<Widget> buildTtsFieldRows({
  required BuildContext context,
  required List<TtsField> fields,
  required TtsProviderConfig config,
  required void Function(String key, Object? value) onChanged,
}) {
  return [
    for (final field in fields)
      buildTtsFieldRow(
        context: context,
        field: field,
        config: config,
        storageKey: field.key,
        onChanged: onChanged,
      ),
  ];
}

Widget buildTtsFieldRow({
  required BuildContext context,
  required TtsField field,
  required TtsProviderConfig config,
  required String storageKey,
  required void Function(String key, Object? value) onChanged,
}) {
  final raw = config.values[storageKey];
  switch (field.kind) {
    case TtsFieldKind.text:
    case TtsFieldKind.secret:
    case TtsFieldKind.multiline:
      return TtsTextFieldRow(
        key: ValueKey(storageKey),
        label: field.label,
        value: raw?.toString() ?? (field.defaultValue as String? ?? ''),
        hint: field.hint,
        obscure: field.kind == TtsFieldKind.secret,
        multiline: field.kind == TtsFieldKind.multiline,
        onChanged: (v) => onChanged(storageKey, v),
      );
    case TtsFieldKind.number:
      final value = raw is num ? raw.toDouble() : field.defaultValue as double;
      final steps = ((field.max - field.min) / field.step).round();
      return MenuRangeItem(
        key: ValueKey(storageKey),
        label: field.label,
        description: field.hint,
        value: value.clamp(field.min, field.max),
        min: field.min,
        max: field.max,
        divisions: steps.clamp(1, 1000),
        decimalPlaces: field.step >= 1 ? 0 : (field.step >= 0.1 ? 1 : 2),
        onChanged: (v) => onChanged(storageKey, v),
        onReset: value != field.defaultValue
            ? () => onChanged(storageKey, null)
            : null,
      );
    case TtsFieldKind.toggle:
      return MenuSwitchItem(
        key: ValueKey(storageKey),
        label: field.label,
        description: field.hint,
        value: raw is bool ? raw : field.defaultValue as bool,
        onChanged: (v) => onChanged(storageKey, v),
      );
    case TtsFieldKind.select:
      final current = raw?.toString() ?? field.defaultValue as String;
      final label = field.options
              .where((o) => o.value == current)
              .map((o) => o.label)
              .firstOrNull ??
          current;
      return MenuSelectorItem(
        key: ValueKey(storageKey),
        label: field.label,
        description: field.hint,
        currentValue: label,
        onTap: () => showTtsOptions<TtsFieldOption>(
          context,
          title: field.label,
          items: field.options,
          labelOf: (o) => o.label,
          isSelected: (o) => o.value == current,
          onSelected: (o) => onChanged(storageKey, o.value),
        ),
      );
  }
}

/// Single-choice picker in the kit's sheet, check mark on the current value.
void showTtsOptions<T>(
  BuildContext context, {
  required String title,
  required List<T> items,
  required String Function(T) labelOf,
  required bool Function(T) isSelected,
  required void Function(T) onSelected,
  String? Function(T)? hintOf,
  List<BottomSheetAction> Function(T)? actionsOf,
  bool searchable = false,
}) {
  GlazeBottomSheet.show<void>(
    context,
    title: title,
    searchable: searchable,
    searchHint: searchable ? 'tts_search_voices'.tr() : null,
    items: [
      for (final item in items)
        BottomSheetItem(
          label: labelOf(item),
          hint: hintOf?.call(item),
          icon: isSelected(item) ? Icons.check : null,
          actions: actionsOf?.call(item) ?? const [],
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            onSelected(item);
          },
        ),
    ],
  );
}

/// [MenuFieldItem] that owns its controller and keeps it in step with an
/// externally changing value.
class TtsTextFieldRow extends StatefulWidget {
  final String label;
  final String value;
  final String? hint;
  final bool obscure;
  final bool multiline;
  final ValueChanged<String> onChanged;

  const TtsTextFieldRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
    this.obscure = false,
    this.multiline = false,
  });

  @override
  State<TtsTextFieldRow> createState() => _TtsTextFieldRowState();
}

class _TtsTextFieldRowState extends State<TtsTextFieldRow> {
  late final _controller = TextEditingController(text: widget.value);
  bool _hidden = true;

  @override
  void didUpdateWidget(covariant TtsTextFieldRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _controller.text && widget.value != oldWidget.value) {
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
      placeholder: widget.multiline ? null : widget.hint,
      description: widget.multiline ? widget.hint : null,
      obscure: widget.obscure && _hidden,
      maxLines: widget.multiline ? 6 : 1,
      minLines: widget.multiline ? 2 : null,
      onChanged: widget.onChanged,
      suffix: widget.obscure
          ? IconButton(
              icon: Icon(
                _hidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 20,
                color: context.cs.onSurfaceVariant,
              ),
              onPressed: () => setState(() => _hidden = !_hidden),
            )
          : null,
    );
  }
}
