import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../services/sync_engine.dart';

Widget buildSyncSectionHeader(BuildContext context, String title) {
  return Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8, top: 12),
    child: Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Theme.of(
          context,
        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        letterSpacing: 0.5,
      ),
    ),
  );
}

Widget buildSyncProviderButton({
  required Widget icon,
  required String label,
  required Color color,
  required VoidCallback? onPressed,
}) {
  final disabled = onPressed == null;
  return Material(
    color: color,
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onPressed,
      child: Opacity(
        opacity: disabled ? 0.7 : 1.0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              icon,
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget buildSyncManualButton({
  required BuildContext context,
  required VoidCallback? onPressed,
  required IconData icon,
  required String label,
  required bool primary,
}) {
  final accent = context.colors.accent;
  final bg = primary ? accent : accent.withValues(alpha: 0.1);
  final fg = primary ? Colors.white : accent;
  final disabled = onPressed == null;

  return Material(
    color: bg,
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onPressed,
      child: Opacity(
        opacity: disabled ? 0.7 : 1.0,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: fg),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget buildSyncDangerButton({
  required IconData icon,
  required String label,
  required VoidCallback? onPressed,
  bool light = false,
}) {
  final disabled = onPressed == null;
  final bg = light
      ? const Color(0xFFFF3B30).withValues(alpha: 0.05)
      : const Color(0xFFFF3B30).withValues(alpha: 0.1);
  return Material(
    color: bg,
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onPressed,
      child: Opacity(
        opacity: disabled ? 0.7 : 1.0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: const Color(0xFFFF3B30)),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFFF3B30),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget buildSyncCountButton({required IconData icon, VoidCallback? onPressed}) {
  return Material(
    color: Colors.white.withValues(alpha: 0.05),
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onPressed,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 16,
          color: onPressed == null ? Colors.white24 : Colors.white70,
        ),
      ),
    ),
  );
}

Widget buildSyncErrorCard(String error) {
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFF3B30).withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, color: Color(0xFFFF3B30), size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            error,
            style: const TextStyle(
              color: Color(0xFFFF3B30),
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}

Widget buildSyncResultCard(BuildContext context, Map<String, dynamic> result) {
  final type = result['type'] as String;
  final pushed = result['pushed'] as int? ?? 0;
  final pulled = result['pulled'] as int? ?? 0;
  final deleted = result['deleted'] as int? ?? 0;
  final total = result['total'] as String?;
  final conflictsCount = result['conflictsCount'] as int? ?? 0;

  String message = '';
  Color cardColor = const Color(0xFF4CAF50).withValues(alpha: 0.1);
  Color textColor = const Color(0xFF4CAF50);

  if (type == 'push') {
    message = 'Pushed: $pushed items';
  } else if (type == 'pull') {
    message = 'Pulled: $pulled items';
    if (conflictsCount > 0) {
      message += ', $conflictsCount conflicts';
    }
    cardColor = context.colors.accent.withValues(alpha: 0.1);
    textColor = context.colors.accent;
  } else if (type == 'wipe') {
    message = (total == 'all')
        ? 'Cloud data wiped'
        : 'Deleted: $deleted/${total ?? "?"} items';
  } else {
    message = 'Full sync complete';
  }

  return Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: cardColor,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            message,
            style: TextStyle(
              fontSize: 13,
              color: textColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (type == 'pull' && conflictsCount > 0)
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: Colors.orange.withValues(alpha: 0.15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            onPressed: () {},
            child: const Text(
              'Resolve',
              style: TextStyle(
                fontSize: 12,
                color: Colors.orangeAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
      ],
    ),
  );
}

Widget buildSyncProgressBar(BuildContext context, SyncProgress p) {
  final indeterminate = p.total <= 0;
  final pct = indeterminate ? null : (p.current / p.total).clamp(0.0, 1.0);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 12),
      if (p.message != null)
        Text(
          p.message!,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: pct,
          backgroundColor: Colors.white.withValues(alpha: 0.1),
          valueColor: AlwaysStoppedAnimation<Color>(context.colors.accent),
          minHeight: 4,
        ),
      ),
      if (!indeterminate) ...[
        const SizedBox(height: 4),
        Text(
          '${p.current}/${p.total}',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      ],
    ],
  );
}
