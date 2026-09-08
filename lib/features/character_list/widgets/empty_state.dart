import 'package:flutter/material.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_scaffold.dart';

class EmptyCharacterState extends StatelessWidget {
  final VoidCallback onImport;

  const EmptyCharacterState({super.key, required this.onImport});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.group_outlined,
              size: 64,
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(
            'No characters yet',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w500,
              color: context.cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          GlazePillButton(
            icon: Icons.add_rounded,
            label: 'Import Character',
            onTap: onImport,
          ),
        ],
      ),
    );
  }
}
