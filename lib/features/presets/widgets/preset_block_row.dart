import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/llm/tokenizer.dart';
import '../../../core/models/preset.dart';
import '../../../shared/theme/app_colors.dart';

IconData presetBlockRoleIcon(String role) {
  return switch (role) {
    'user' => Icons.person_outline,
    'assistant' => Icons.smart_toy_outlined,
    _ => Icons.storage_outlined,
  };
}

class PresetBlockRow extends StatelessWidget {
  final PresetBlock block;
  final int index;
  final bool isLast;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;

  const PresetBlockRow({
    super.key,
    required this.block,
    required this.index,
    required this.isLast,
    required this.onEdit,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: const Color(0x33808080),
            width: isLast ? 0 : 1,
          ),
        ),
      ),
      child: Opacity(
        opacity: block.enabled ? 1.0 : 0.5,
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: SizedBox(
                width: 30,
                height: 44,
                child: Center(
                  child: Text(
                    '≡',
                    style: TextStyle(
                      fontSize: 20,
                      color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ),
            Icon(
              presetBlockRoleIcon(block.role),
              size: 16,
              color: context.cs.onSurface.withValues(alpha: 0.6),
            ),
            const SizedBox(width: 8),
            if (block.isStatic) ...[
              _systemBadge(context),
              const SizedBox(width: 8),
            ] else if (block.appendToLastMessage) ...[
              _appendBadge(context),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        block.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: context.cs.onSurface,
                        ),
                      ),
                    ),
                    if (block.content.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${estimateTokens(block.content)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: context.cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Author's Note and Summary are static blocks but stay editable:
            // tapping opens an editor for their per-preset settings, with the
            // session-scoped content shown/linked.
            if (!block.isStatic ||
                block.id == 'authors_note' ||
                block.id == 'summary')
              SizedBox(
                width: 36,
                height: 44,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onEdit,
                    child: Icon(
                      Icons.edit_outlined,
                      size: 20,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              const SizedBox(width: 36),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Transform.scale(
                scale: 0.8,
                alignment: Alignment.centerRight,
                child: Switch(
                  value: block.enabled,
                  onChanged: onToggle,
                  activeThumbColor: context.cs.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _systemBadge(BuildContext context) {
  return Tooltip(
    message: 'System block — injected automatically',
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'System',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Colors.white.withValues(alpha: 0.4),
          letterSpacing: 0.2,
        ),
      ),
    ),
  );
}

Widget _appendBadge(BuildContext context) {
  return Tooltip(
    message: 'block_append_to_last_user'.tr(),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: context.cs.primary.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '↩ Last User',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: context.cs.primary,
          letterSpacing: 0.2,
        ),
      ),
    ),
  );
}
