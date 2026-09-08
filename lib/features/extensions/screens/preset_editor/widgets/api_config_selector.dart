import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/models/api_config.dart';
import '../../../../../shared/theme/app_colors.dart';
import '../../../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../../settings/api_list_provider.dart';

class ApiConfigSelector extends ConsumerWidget {
  const ApiConfigSelector({
    required this.selectedId,
    required this.onSelected,
    super.key,
  });

  final String selectedId;
  final ValueChanged<String?> onSelected;

  String _displayName(List<ApiConfig> configs) {
    if (selectedId.isEmpty) return 'Использовать основной';
    final cfg = configs.where((c) => c.id == selectedId).firstOrNull;
    if (cfg == null) return 'Не найдено';
    return cfg.name.isNotEmpty ? cfg.name : 'Без имени';
  }

  Future<void> _open(BuildContext context, List<ApiConfig> configs) async {
    String? pendingSelection;
    await GlazeBottomSheet.show<void>(
      context,
      title: 'Выберите API',
      items: [
        BottomSheetItem(
          label: 'Использовать основной',
          icon: selectedId.isEmpty
              ? Icons.radio_button_checked
              : Icons.radio_button_off,
          iconColor: selectedId.isEmpty
              ? context.cs.primary
              : context.cs.onSurfaceVariant,
          onTap: () {
            pendingSelection = null;
            Navigator.of(context, rootNavigator: true).pop();
          },
        ),
        ...configs.map((cfg) {
          final name = cfg.name.isNotEmpty ? cfg.name : 'Без имени';
          return BottomSheetItem(
            label: name,
            icon: selectedId == cfg.id
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            iconColor: selectedId == cfg.id
                ? context.cs.primary
                : context.cs.onSurfaceVariant,
            onTap: () {
              pendingSelection = cfg.id;
              Navigator.of(context, rootNavigator: true).pop();
            },
          );
        }),
      ],
    );
    onSelected(pendingSelection);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configsAsync = ref.watch(apiListProvider);
    final configs = configsAsync.value ?? const <ApiConfig>[];

    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () => _open(context, configs),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.cloud_outlined,
                size: 20,
                color: Color(0xFF99A2AD),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _displayName(configs),
                  style: TextStyle(fontSize: 14, color: context.cs.onSurface),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
