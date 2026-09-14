import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/model_fetcher.dart';
import '../../../core/llm/transport/llm_protocol.dart';
import '../../../core/models/api_config.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../api_list_provider.dart';

/// One model override row inside an [ApiSlotGroup].
///
/// A slot normally has one (the model the stage runs on); the Post Clean slot
/// has two, because its fact-check pass may use a cheaper model on the same
/// connection. [cacheTag] is what keeps the two rows' fetched model lists
/// apart — everything else about the fetch is identical.
class ApiSlotModelRow {
  final String value;
  final ValueChanged<String> onChanged;

  /// Defaults to the generic "Model override" label.
  final String? label;
  final String? description;
  final String cacheTag;

  const ApiSlotModelRow({
    required this.value,
    required this.onChanged,
    this.label,
    this.description,
    this.cacheTag = 'model',
  });
}

/// A model-routing slot rendered as one settings group: which API connection
/// it runs on, which model it overrides to, and whatever extra rows the caller
/// hangs off it.
///
/// Every auxiliary LLM call in the app is bound this way — the Studio stages on
/// the Agents tab, and MemoryBook draft generation in its own sheet — so the
/// rows, the pickers and the fetched-model cache live here once rather than
/// being copied into each screen that needs them.
///
/// The cache is keyed by the connection the list was fetched from (its id, its
/// endpoint and its model), so picking another connection — or editing the one
/// selected — can never show models belonging to a different endpoint. There
/// is nothing to invalidate by hand.
class ApiSlotGroup extends ConsumerStatefulWidget {
  final String header;
  final String? description;

  /// Empty means "use whichever connection the LLM tab is on".
  final String apiConfigId;
  final ValueChanged<String> onApiConfigChanged;
  final List<ApiSlotModelRow> modelRows;

  /// Rows appended after the connection and the model — a link into per-slot
  /// parameters, a generation limit, anything the slot owns by itself.
  final List<Widget> trailingItems;

  const ApiSlotGroup({
    super.key,
    required this.header,
    this.description,
    required this.apiConfigId,
    required this.onApiConfigChanged,
    required this.modelRows,
    this.trailingItems = const [],
  });

  @override
  ConsumerState<ApiSlotGroup> createState() => _ApiSlotGroupState();
}

class _ApiSlotGroupState extends ConsumerState<ApiSlotGroup> {
  /// Fetched model ids keyed by `'<cacheTag>:<apiConfigId>|<endpoint>|<model>'`.
  final Map<String, List<String>> _fetchedModels = {};

  /// Cache keys currently in flight, so a second tap does not refetch.
  final Set<String> _fetching = {};

  @override
  Widget build(BuildContext context) {
    final configs = ref.watch(apiListProvider).value ?? const <ApiConfig>[];
    return MenuGroup(
      header: widget.header,
      description: widget.description,
      items: [
        MenuSelectorItem(
          label: 'studio_slot_api'.tr(),
          currentValue: _apiName(configs, widget.apiConfigId),
          onTap: () => _pickApiConfig(configs),
        ),
        for (final row in widget.modelRows)
          MenuSelectorItem(
            label: row.label ?? 'studio_slot_model'.tr(),
            description: row.description,
            currentValue: row.value.isEmpty
                ? 'studio_slot_model_auto'.tr()
                : row.value,
            onTap: () => _openModelSelector(row),
          ),
        ...widget.trailingItems,
      ],
    );
  }

  String _apiName(List<ApiConfig> configs, String id) {
    if (id.isEmpty) return 'studio_slot_use_chat_api'.tr();
    final config = configs.where((c) => c.id == id).firstOrNull;
    if (config == null) return 'unnamed_entry'.tr();
    return _configLabel(config);
  }

  static String _configLabel(ApiConfig config) {
    if (config.name.isNotEmpty) return config.name;
    if (config.model.isNotEmpty) return config.model;
    return 'unnamed_entry'.tr();
  }

  void _pickApiConfig(List<ApiConfig> configs) {
    BottomSheetItem radio(String id, String label) => BottomSheetItem(
      label: label,
      icon: widget.apiConfigId == id
          ? Icons.radio_button_checked
          : Icons.radio_button_off,
      iconColor: widget.apiConfigId == id
          ? Theme.of(context).colorScheme.primary
          : Theme.of(context).colorScheme.onSurfaceVariant,
      onTap: () {
        Navigator.of(context, rootNavigator: true).pop();
        widget.onApiConfigChanged(id);
      },
    );

    GlazeBottomSheet.show<void>(
      context,
      title: 'studio_slot_api'.tr(),
      items: [
        radio('', 'studio_slot_use_chat_api'.tr()),
        for (final config in configs) radio(config.id, _configLabel(config)),
      ],
    );
  }

  // ── Fetched model picker ───────────────────────────────────────────────────

  /// The connection named by the row above the model picker: the slot's own
  /// selection, or — only while the slot is left on "Use selected LLM
  /// connection" — the active LLM preset.
  ///
  /// A slot pointing at a deleted config resolves to null rather than falling
  /// through to the active preset, so the picker can never list models from an
  /// endpoint other than the one the row displays.
  ApiConfig? _slotApiConfig(List<ApiConfig> configs) {
    if (widget.apiConfigId.isNotEmpty) {
      return configs.where((c) => c.id == widget.apiConfigId).firstOrNull;
    }
    return ref.read(activeApiConfigProvider);
  }

  String _cacheKey(String cacheTag, List<ApiConfig> configs) {
    final config = _slotApiConfig(configs);
    final identity = config == null
        ? widget.apiConfigId
        : '${config.id}|${config.endpoint}|${config.model}';
    return '$cacheTag:$identity';
  }

  Future<void> _fetchModels(String cacheKey, List<ApiConfig> configs) async {
    if (_fetching.contains(cacheKey)) return;
    final config = _slotApiConfig(configs);
    if (config == null) {
      GlazeToast.show(context, 'studio_slot_no_api'.tr());
      return;
    }
    // Same precondition as the LLM tab's fetch button: OpenRouter's URL is
    // hardcoded, every other protocol needs an endpoint of its own.
    final endpointRequired = config.protocol != LlmProtocol.openrouter;
    if ((endpointRequired && config.endpoint.trim().isEmpty) ||
        config.apiKey.trim().isEmpty) {
      GlazeToast.show(context, 'settings_err_endpoint_key'.tr());
      return;
    }
    setState(() => _fetching.add(cacheKey));
    try {
      final ids = await ModelFetcher.fetchModelIds(config);
      if (!mounted) return;
      setState(() => _fetchedModels[cacheKey] = ids);
    } catch (e) {
      if (mounted) {
        GlazeErrorDialog.show(context, e, prefix: 'settings_err_failed'.tr());
      }
    } finally {
      if (mounted) setState(() => _fetching.remove(cacheKey));
    }
  }

  Future<void> _openModelSelector(ApiSlotModelRow row) async {
    final configs = ref.read(apiListProvider).value ?? const <ApiConfig>[];
    final cacheKey = _cacheKey(row.cacheTag, configs);
    if ((_fetchedModels[cacheKey] ?? const <String>[]).isEmpty) {
      await _fetchModels(cacheKey, configs);
      if (!mounted) return;
    }
    final models =
        <String>{
          ...?_fetchedModels[cacheKey],
          if (row.value.isNotEmpty) row.value,
        }.toList()
          ..sort();
    // "Automatic" is always offered, even when the fetch came back empty —
    // otherwise a slot pointed at a stale model id could never be reset.
    final items = <BottomSheetItem>[
      BottomSheetItem(
        label: 'studio_slot_model_auto'.tr(),
        icon: row.value.isEmpty ? Icons.check : null,
        iconColor: Theme.of(context).colorScheme.primary,
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          row.onChanged('');
        },
      ),
      for (final m in models)
        BottomSheetItem(
          label: m,
          icon: m == row.value ? Icons.check : null,
          iconColor: Theme.of(context).colorScheme.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            row.onChanged(m);
          },
        ),
    ];
    if (models.isEmpty) GlazeToast.show(context, 'settings_err_no_models'.tr());
    final selectedIndex = models.indexOf(row.value);
    await GlazeBottomSheet.show<void>(
      context,
      title: 'onboarding_select_model'.tr(),
      // +1 for the leading "Automatic" entry.
      scrollToIndex: selectedIndex >= 0 ? selectedIndex + 1 : null,
      items: items,
    );
  }
}
