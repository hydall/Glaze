import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glass_surface.dart';

/// One message of a captured request, as it went out.
class RequestMessageCard extends StatelessWidget {
  const RequestMessageCard({
    super.key,
    required this.index,
    required this.message,
  });

  final int index;
  final Map<String, dynamic> message;

  @override
  Widget build(BuildContext context) {
    final role = '${message['role'] ?? 'unknown'}';
    final content = message['content'];
    final text = content is String
        ? content
        : const JsonEncoder.withIndent('  ').convert(content);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    role.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: context.cs.primary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '#${index + 1}',
                    style: TextStyle(
                      fontSize: 10,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SelectableText(
                text,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: context.cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
