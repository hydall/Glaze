import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../image_gen/image_gen_models.dart';
import '../../image_gen/image_gen_provider.dart';
import '../../settings/widgets/api_slot_group.dart';
import '../models/installed_plugin.dart';
import '../models/plugin_settings_schema.dart';
import '../providers/plugin_library_provider.dart';
import '../services/plugin_localizer.dart';

/// Renders `contributes.settings` (or one tab of it) as Glaze menu groups. `break`
/// starts a new group; `divider` too, since groups are already separated.
/// An `apiPreset` is a group of its own: the [ApiSlotGroup] every other
/// auxiliary call binds its connection with. An `imagePreset` is a group with
/// the image service and the style.
class PluginSettingsForm extends ConsumerWidget {
  const PluginSettingsForm({
    super.key,
    required this.plugin,
    required this.localizer,
    this.tab,
  });

  final InstalledPlugin plugin;
  final PluginLocalizer localizer;

  /// Only the fields on this [PluginSettingsTab]; null for every field.
  final String? tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final values = plugin.effectiveConfig(localizer);
    final sections = <Widget>[];
    var items = <Widget>[];
    // The tab's name is in the screen's header; the groups need none.
    void close() {
      if (items.isEmpty) return;
      sections.add(MenuGroup(items: items));
      items = [];
    }

    final firstTab = plugin.manifest.settingsTabs.firstOrNull?.id;
    for (final field in plugin.manifest.settings) {
      if (tab != null && (field.tab ?? firstTab) != tab) continue;
      switch (field.type) {
        case PluginSettingType.group:
        case PluginSettingType.divider:
          close();
        case PluginSettingType.apiPreset:
        case PluginSettingType.imagePreset:
          close();
          sections.add(_preset(ref, field));
        default:
          items.add(_field(context, ref, field, values));
      }
    }
    close();
    return Column(children: sections);
  }

  Widget _preset(WidgetRef ref, PluginSettingField field) {
    final notifier = ref.read(pluginLibraryProvider.notifier);
    final key = field.key!;
    final value = PluginPresetValue.parse(plugin.config[key]);
    void set(PluginPresetValue v) {
      final json = v.toJson();
      json.isEmpty
          ? notifier.resetConfigValue(plugin.id, key)
          : notifier.setConfigValue(plugin.id, key, json);
    }

    if (field.type == PluginSettingType.imagePreset) {
      return MenuGroup(
        header: localizer.resolve(field.label),
        description: field.description == null
            ? 'plugins_generation_image_desc'.tr()
            : localizer.resolve(field.description),
        items: [
          _ImageProviderRow(
            provider: value.provider,
            // Only the service and the style are drawn with; a connection
            // stored by an earlier Glaze is dropped on the first change.
            onChanged: (p) => set(value.copyWith(api: '', provider: p)),
          ),
          _ImageStyleRow(
            style: value.style,
            onChanged: (s) => set(value.copyWith(api: '', style: s)),
          ),
        ],
      );
    }
    return ApiSlotGroup(
      header: localizer.resolve(field.label),
      description: field.description == null
          ? 'plugins_generation_desc'.tr()
          : localizer.resolve(field.description),
      apiConfigId: value.api,
      onApiConfigChanged: (id) => set(
        // A model chosen against the previous connection would not resolve.
        value.copyWith(api: id, model: id == value.api ? null : ''),
      ),
      modelRows: [
        ApiSlotModelRow(
          value: value.model,
          description: 'plugins_generation_model_desc'.tr(),
          onChanged: (m) => set(value.copyWith(model: m)),
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
      case PluginSettingType.apiPreset:
      case PluginSettingType.imagePreset:
        return const SizedBox.shrink();
    }
  }
}

/// The image service an `imagePreset` draws with: the one the image settings
/// have active, or another one of those set up there (each keeps its own key,
/// model and options in the image settings).
class _ImageProviderRow extends ConsumerWidget {
  const _ImageProviderRow({required this.provider, required this.onChanged});

  final String provider;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(imageGenSettingsProvider).value?.apiType;
    final picked = ImageGenApiType.values
        .where((t) => t.name == provider)
        .firstOrNull;
    final follow = 'plugins_generation_provider_settings'.tr(
      args: [active?.label ?? '—'],
    );
    void pick(String name) {
      onChanged(name);
      Navigator.of(context, rootNavigator: true).pop();
    }

    return MenuSelectorItem(
      label: 'plugins_generation_provider'.tr(),
      description: 'plugins_generation_provider_desc'.tr(),
      currentValue: picked?.label ?? follow,
      onReset: picked == null ? null : () => onChanged(''),
      onTap: () => GlazeBottomSheet.show<void>(
        context,
        title: 'plugins_generation_provider'.tr(),
        items: [
          BottomSheetItem(
            label: follow,
            icon: picked == null ? Icons.check_rounded : null,
            onTap: () => pick(''),
          ),
          for (final t in ImageGenApiType.values)
            BottomSheetItem(
              label: t.label,
              icon: picked == t ? Icons.check_rounded : null,
              onTap: () => pick(t.name),
            ),
        ],
      ),
    );
  }
}

/// The style an `imagePreset` draws in: whatever the image settings have
/// active, none at all, or one named in the style library.
class _ImageStyleRow extends ConsumerWidget {
  const _ImageStyleRow({required this.style, required this.onChanged});

  final String style;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final styles =
        ref.watch(imageGenSettingsProvider).value?.styles ??
        const <ImageStyle>[];
    final String value;
    if (style.isEmpty) {
      value = 'plugins_generation_style_settings'.tr();
    } else if (style == kPluginNoImageStyle) {
      value = 'plugins_generation_style_none'.tr();
    } else {
      value =
          styles.where((s) => s.id == style).firstOrNull?.name ??
          'plugins_generation_style_missing'.tr();
    }
    void pick(String id) {
      onChanged(id);
      Navigator.of(context, rootNavigator: true).pop();
    }

    return MenuSelectorItem(
      label: 'plugins_generation_style'.tr(),
      description: 'plugins_generation_style_desc'.tr(),
      currentValue: value,
      onReset: style.isEmpty ? null : () => onChanged(''),
      onTap: () => GlazeBottomSheet.show<void>(
        context,
        title: 'plugins_generation_style'.tr(),
        items: [
          BottomSheetItem(
            label: 'plugins_generation_style_settings'.tr(),
            icon: style.isEmpty ? Icons.check_rounded : null,
            onTap: () => pick(''),
          ),
          BottomSheetItem(
            label: 'plugins_generation_style_none'.tr(),
            icon: style == kPluginNoImageStyle ? Icons.check_rounded : null,
            onTap: () => pick(kPluginNoImageStyle),
          ),
          for (final s in styles)
            BottomSheetItem(
              label: s.name,
              icon: style == s.id ? Icons.check_rounded : null,
              onTap: () => pick(s.id),
            ),
        ],
      ),
    );
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
