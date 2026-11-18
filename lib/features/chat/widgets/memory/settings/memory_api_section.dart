import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../../core/llm/memory_book_api_config_resolver.dart';
import '../../../../../core/models/memory_book_api_settings.dart';
import '../../../../../shared/theme/app_colors.dart';
import '../../../../../shared/widgets/menu_group.dart';
import '../../../../settings/widgets/api_slot_group.dart';

/// The API block of the memory settings sheet: the connection drafts are
/// written on, the model they are written with, and the two request limits
/// that belong to drafting rather than to the connection.
///
/// It is the same [ApiSlotGroup] the Agents tab binds every other auxiliary
/// LLM call with, so the connection and model rows read and behave identically
/// — but it lives here, next to the prompt and the automation that use it,
/// instead of only behind a link into API settings.
///
/// Unlike the Agents tab it does not write through on change: the edit goes to
/// the sheet's draft and is persisted with everything else when Save is
/// pressed, which is what stopped a dismissed sheet from silently keeping a
/// model the user was only trying out.
class MemoryApiSections {
  final MemoryBookApiSettings api;

  /// Hands back the edited settings; the host stores them on its draft.
  final ValueChanged<MemoryBookApiSettings> onChanged;

  /// Opens the full API screen on this slot. The host commits the buffered
  /// edit first, so the screen never shows a connection the sheet has already
  /// moved on from.
  final VoidCallback onOpenApiSettings;

  const MemoryApiSections({
    required this.api,
    required this.onChanged,
    required this.onOpenApiSettings,
  });

  /// The value a newly enabled output-limit slider starts from, so switching
  /// the override on does not jump to the slider's minimum.
  static const int _defaultMaxTokens = 8000;

  List<Widget> build(BuildContext context) {
    return [
      ApiSlotGroup(
        header: 'tab_api'.tr(),
        description: 'memory_books_slot_desc'.tr(),
        apiConfigId: api.apiConfigId,
        onApiConfigChanged: (id) => onChanged(
          api.copyWith(
            apiConfigId: id,
            // Endpoint and key always come from the selected connection; a
            // model chosen against the previous one would not resolve.
            generationSource: 'current',
            generationModel: '',
          ),
        ),
        modelRows: [
          ApiSlotModelRow(
            value: api.generationModel,
            onChanged: (value) => onChanged(
              api.copyWith(generationModel: value),
            ),
          ),
        ],
        trailingItems: [
          MenuRangeItem(
            label: 'memory_books_generation_max_tokens'.tr(),
            description: 'memory_books_generation_max_tokens_desc'.tr(),
            value: (api.generationMaxTokens ?? _defaultMaxTokens).toDouble(),
            min: 512,
            max: 32000,
            divisions: 123,
            decimalPlaces: 0,
            editableValue: true,
            // Off means "auto": the request inherits the limit configured on
            // the connection above. Turning it on is how a provider that caps
            // output plus reasoning tokens is brought back under its ceiling.
            included: api.generationMaxTokens != null,
            onIncludedChanged: (on) => onChanged(
              api.copyWith(
                generationMaxTokens: on
                    ? (api.generationMaxTokens ?? _defaultMaxTokens)
                    : null,
              ),
            ),
            onChanged: (value) => onChanged(
              api.copyWith(generationMaxTokens: value.round()),
            ),
          ),
          MenuRangeItem(
            label: 'memory_books_generation_temperature'.tr(),
            description: 'memory_books_generation_temperature_desc'.tr(),
            value:
                api.generationTemperature ?? kMemoryDraftDefaultTemperature,
            min: 0,
            max: 2,
            divisions: 200,
            editableValue: true,
            included: api.generationTemperature != null,
            onIncludedChanged: (on) => onChanged(
              api.copyWith(
                generationTemperature: on
                    ? (api.generationTemperature ??
                          kMemoryDraftDefaultTemperature)
                    : null,
              ),
            ),
            onChanged: (value) => onChanged(
              api.copyWith(generationTemperature: value),
            ),
          ),
          MenuItem(
            icon: Icons.hub_outlined,
            label: 'memory_books_generation_connection'.tr(),
            subtitle: 'memory_books_api_edit_connection_desc'.tr(),
            trailing: Icon(
              Icons.chevron_right,
              size: 22,
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            onTap: onOpenApiSettings,
          ),
        ],
      ),
    ];
  }
}
