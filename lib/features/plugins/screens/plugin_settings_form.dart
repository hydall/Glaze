import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import '../models/installed_plugin.dart';
import '../models/plugin_settings_schema.dart';
import '../providers/plugin_library_provider.dart';
import '../services/plugin_localizer.dart';

/// Renders `contributes.settings.schema` as Glaze menu groups. `break`
/// starts a new group; `divider` too, since groups are already separated.
class PluginSettingsForm extends ConsumerWidget {
  const PluginSettingsForm({
    super.key,
    required this.plugin,
    required this.localizer,
  });

  final InstalledPlugin plugin;
  final PluginLocalizer localizer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final values = plugin.effectiveConfig(localizer);
    final groups = <List<Widget>>[[]];
    for (final field in plugin.manifest.settings) {
      if (field.type == PluginSettingType.group ||
          field.type == PluginSettingType.divider) {
        if (groups.last.isNotEmpty) groups.add([]);
        continue;
      }
      groups.last.add(_field(context, ref, field, values));
    }
    return Column(
      children: [
        for (final (i, items) in groups.indexed)
          if (items.isNotEmpty)
            MenuGroup(
              header: i == 0 ? 'plugins_settings'.tr() : null,
              headerIcon: i == 0 ? Icons.tune_rounded : null,
              items: items,
            ),
      ],
    );
  }

  Widget _field(
    BuildContext context,
    WidgetRef ref,
    PluginSettingField field,
    Map<String, Object?> values,
  ) {
    final notifier = ref.read(pluginLibraryProvider.notifier);
    final key = field.key;
    final label = localizer.resolve(field.label);
    final description = field.description == null
        ? null
        : localizer.resolve(field.description);
    void set(Object? v) => notifier.setConfigValue(plugin.id, key!, v);
    VoidCallback? reset() => key != null && plugin.config.containsKey(key)
        ? () => notifier.resetConfigValue(plugin.id, key)
        : null;

    switch (field.type) {
      case PluginSettingType.note:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                field.icon == 'warning'
                    ? Icons.warning_amber_rounded
                    : Icons.info_outline_rounded,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        );
      case PluginSettingType.toggle:
        return MenuSwitchItem(
          label: label,
          description: description,
          value: values[key] == true,
          onChanged: set,
        );
      case PluginSettingType.slider:
        final min = field.min!;
        final max = field.max!;
        final step = field.step;
        final raw = values[key];
        return MenuRangeItem(
          label: label,
          description: description,
          value: (raw is num ? raw.toDouble() : min).clamp(min, max),
          min: min,
          max: max,
          divisions: step == null
              ? 100
              : ((max - min) / step).round().clamp(1, 1000),
          decimalPlaces: step == null || step >= 1 ? 0 : 2,
          onChanged: set,
          onReset: reset(),
        );
      case PluginSettingType.select:
        final current = values[key]?.toString();
        final selected = field.options
            .where((o) => o.value == current)
            .firstOrNull;
        return MenuSelectorItem(
          label: label,
          description: description,
          currentValue: selected == null
              ? (current ?? '')
              : localizer.resolve(selected.label),
          onReset: reset(),
          onTap: () => GlazeBottomSheet.show<void>(
            context,
            title: label,
            items: [
              for (final o in field.options)
                BottomSheetItem(
                  label: localizer.resolve(o.label),
                  icon: o.value == current ? Icons.check : null,
                  onTap: () {
                    set(o.value);
                    Navigator.of(context, rootNavigator: true).pop();
                  },
                ),
            ],
          ),
        );
      case PluginSettingType.text:
      case PluginSettingType.textarea:
        return _PluginTextSetting(
          key: ValueKey('${plugin.id}/$key'),
          label: label,
          description: description,
          value: values[key]?.toString() ?? '',
          multiline: field.type == PluginSettingType.textarea,
          onChanged: set,
          onReset: reset(),
        );
      case PluginSettingType.divider:
      case PluginSettingType.group:
        return const SizedBox.shrink();
    }
  }
}

class _PluginTextSetting extends StatefulWidget {
  const _PluginTextSetting({
    super.key,
    required this.label,
    required this.description,
    required this.value,
    required this.multiline,
    required this.onChanged,
    required this.onReset,
  });

  final String label;
  final String? description;
  final String value;
  final bool multiline;
  final ValueChanged<String> onChanged;
  final VoidCallback? onReset;

  @override
  State<_PluginTextSetting> createState() => _PluginTextSettingState();
}

class _PluginTextSettingState extends State<_PluginTextSetting> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );
  Timer? _debounce;

  @override
  void didUpdateWidget(covariant _PluginTextSetting old) {
    super.didUpdateWidget(old);
    // A reset (or a change made elsewhere) replaces the text only when the
    // field is not mid-edit.
    if (widget.value != _controller.text && _debounce?.isActive != true) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    final pending = _debounce?.isActive == true;
    _debounce?.cancel();
    if (pending) widget.onChanged(_controller.text);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MenuFieldItem(
      label: widget.label,
      description: widget.description,
      controller: _controller,
      maxLines: widget.multiline ? 8 : 1,
      minLines: widget.multiline ? 3 : null,
      onReset: widget.onReset,
      onChanged: (text) {
        _debounce?.cancel();
        _debounce = Timer(
          const Duration(milliseconds: 500),
          () => widget.onChanged(text),
        );
      },
    );
  }
}
