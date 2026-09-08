import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Shared building blocks for the "connections" bottom sheets
/// (persona / preset / lorebook). Extracted from the previously duplicated
/// private widgets so all three sheets render identically. Base layout taken
/// from the persona/preset connections sheets (the SheetView-based variants).

/// A titled section with a leading icon and an optional trailing "+" button.
class ConnectionSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback? onAdd;
  final Widget child;

  const ConnectionSection({
    super.key,
    required this.icon,
    required this.title,
    this.onAdd,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: context.cs.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (onAdd != null)
                IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: onAdd,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ],
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

/// A labelled row with a trailing [Switch] (e.g. the "global enabled" toggle).
class ConnectionToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const ConnectionToggleRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            label,
            style: TextStyle(fontSize: 14, color: context.cs.onSurface),
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: context.cs.primary,
        ),
      ],
    );
  }
}

/// A removable chip whose label is resolved asynchronously (name lookup).
/// Falls back to [id] while the future is pending.
class ConnectionChip extends StatelessWidget {
  final String id;
  final Future<String> futureLabel;
  final VoidCallback onRemove;

  const ConnectionChip({
    super.key,
    required this.id,
    required this.futureLabel,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: FutureBuilder<String>(
        future: futureLabel,
        builder: (_, snap) =>
            Text(snap.data ?? id, style: const TextStyle(fontSize: 12)),
      ),
      deleteIcon: const Icon(Icons.close, size: 14),
      onDeleted: onRemove,
      visualDensity: VisualDensity.compact,
      backgroundColor: Colors.white.withValues(alpha: 0.08),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
    );
  }
}

/// Italic placeholder shown when a section has no connections.
class ConnectionEmptyHint extends StatelessWidget {
  final String text;
  const ConnectionEmptyHint(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: context.cs.onSurfaceVariant.withValues(alpha: 0.6),
        fontStyle: FontStyle.italic,
      ),
    );
  }
}

/// A small pill indicating whether a scope (global / character / chat) is
/// currently active. Used by the lorebook connections sheet.
class ConnectionScopeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color color;

  const ConnectionScopeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: selected
            ? color.withValues(alpha: 0.3)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: selected ? color : Colors.white.withValues(alpha: 0.1),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: selected ? color : context.cs.onSurfaceVariant,
        ),
      ),
    );
  }
}
