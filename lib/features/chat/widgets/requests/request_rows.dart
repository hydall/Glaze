import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glass_surface.dart';
import '../../services/prompt_capture_view_service.dart';
import 'request_stage_label.dart';

class RequestPreviewRow extends StatelessWidget {
  const RequestPreviewRow({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.visibility_outlined, size: 18, color: context.cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'requests_next_request'.tr(),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface,
                    ),
                  ),
                  Text(
                    'requests_next_request_desc'.tr(),
                    style: TextStyle(
                      fontSize: 11,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: context.cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class RequestRow extends StatelessWidget {
  const RequestRow({
    super.key,
    required this.capture,
    required this.onTap,
  });

  final PromptCaptureView capture;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final stage = requestStageLabel(context, capture.row.stage);
    final time = DateTime.fromMillisecondsSinceEpoch(capture.row.createdAtMs);
    final model = '${capture.request['model'] ?? ''}';
    final outcome = capture.transportOutcome?.kind;
    final failed = outcome != null && !outcome.endsWith('succeeded');

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: context.cs.onSurface.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: stage.color),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                stage.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: stage.color,
                                ),
                              ),
                            ),
                            if (failed) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.error_outline_rounded,
                                size: 13,
                                color: context.cs.error,
                              ),
                            ],
                            const Spacer(),
                            Text(
                              _formatTime(time),
                              style: TextStyle(
                                fontSize: 11,
                                color: context.cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (model.isNotEmpty) model,
                            'requests_message_count'.tr(
                              args: ['${capture.messages.length}'],
                            ),
                            if (capture.row.attempt != null &&
                                capture.row.attempt! > 1)
                              'requests_attempt'.tr(
                                args: ['${capture.row.attempt}'],
                              ),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: context.cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _formatTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}
