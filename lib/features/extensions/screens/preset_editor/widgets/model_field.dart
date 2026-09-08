import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/llm/sse_client.dart';
import '../../../../../core/models/api_config.dart';
import '../../../../../shared/theme/app_colors.dart';
import '../../../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../../../shared/widgets/glaze_toast.dart';
import '../../../../settings/api_list_provider.dart';

class ModelField extends ConsumerWidget {
  const ModelField({
    required this.controller,
    required this.apiConfigId,
    required this.fetching,
    required this.onFetchStart,
    required this.onFetchEnd,
    super.key,
  });

  final TextEditingController controller;
  final String apiConfigId;
  final bool fetching;
  final VoidCallback onFetchStart;
  final VoidCallback onFetchEnd;

  Future<void> _fetchAndPick(BuildContext context, WidgetRef ref) async {
    if (apiConfigId.isEmpty) {
      GlazeToast.show(context, 'Сначала выберите API');
      return;
    }
    final configs = ref.read(apiListProvider).value ?? const <ApiConfig>[];
    final cfg = configs.where((c) => c.id == apiConfigId).firstOrNull;
    if (cfg == null) {
      GlazeToast.show(context, 'API не найден');
      return;
    }
    if (cfg.endpoint.isEmpty) {
      GlazeToast.show(context, 'У API не задан endpoint');
      return;
    }

    onFetchStart();
    try {
      final models = await SseClient().fetchModels(
        endpoint: cfg.endpoint,
        apiKey: cfg.apiKey,
      );
      if (!context.mounted) return;
      if (models.isEmpty) {
        GlazeToast.show(context, 'Модели не найдены');
        return;
      }
      final ids =
          models
              .map((m) => m['id'] as String?)
              .where((id) => id != null)
              .cast<String>()
              .toList()
            ..sort();
      String? pendingSelection;
      await GlazeBottomSheet.show<void>(
        context,
        title: 'Выберите модель',
        items: ids.map((id) {
          return BottomSheetItem(
            label: id,
            icon: id == controller.text
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            iconColor: id == controller.text
                ? context.cs.primary
                : context.cs.onSurfaceVariant,
            onTap: () {
              pendingSelection = id;
              Navigator.of(context, rootNavigator: true).pop();
            },
          );
        }).toList(),
      );
      if (pendingSelection != null) {
        controller.text = pendingSelection!;
      }
    } catch (e) {
      if (context.mounted) {
        GlazeToast.show(context, 'Ошибка загрузки моделей: $e');
      }
    } finally {
      onFetchEnd();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextField(
      controller: controller,
      style: TextStyle(color: context.cs.onSurface, fontSize: 14),
      decoration: InputDecoration(
        labelText: 'Модель (опционально)',
        labelStyle: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 12),
        hintText: 'Оставьте пустым для модели из API',
        hintStyle: TextStyle(
          color: context.cs.onSurfaceVariant.withValues(alpha: 0.4),
        ),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: context.cs.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: context.cs.primary.withValues(alpha: 0.5),
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        suffixIcon: IconButton(
          icon: fetching
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.cs.primary,
                  ),
                )
              : Icon(
                  Icons.download_rounded,
                  size: 20,
                  color: context.cs.onSurfaceVariant,
                ),
          tooltip: 'Загрузить список моделей',
          onPressed: fetching ? null : () => _fetchAndPick(context, ref),
        ),
      ),
    );
  }
}
