import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import 'inspector_surface.dart';

/// The timeline's row for the request that has not been sent yet.
///
/// There is exactly one of these. Coverage of the next request used to sit next
/// to it as a second row, which put one request on screen twice; it is now a
/// block inside the preview this row opens, between the parameters and the
/// messages — where a captured request carries its own.
class RequestPreviewRow extends StatelessWidget {
  const RequestPreviewRow({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;

    return InspectorPlaque(
      onTap: onTap,
      child: Row(
        children: [
          Icon(Icons.visibility_outlined, size: 18, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'requests_next_request'.tr(),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                Text(
                  'requests_next_request_desc'.tr(),
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: cs.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}
