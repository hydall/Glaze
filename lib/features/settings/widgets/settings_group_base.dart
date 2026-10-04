import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/menu_group.dart';
import '../app_settings_provider.dart';
import 'settings_highlight.dart';

/// Base for the settings groups: they all read the same notifier and wrap their
/// rows the same way.
abstract class SettingsGroup extends ConsumerWidget {
  final AppSettings settings;
  final String? highlightId;

  const SettingsGroup({
    super.key,
    required this.settings,
    required this.highlightId,
  });

  AppSettingsNotifier notifierOf(WidgetRef ref) =>
      ref.read(appSettingsProvider.notifier);

  /// A switch row bound to one [AppSettings] flag, flashing when the search
  /// deep-linked to it.
  Widget toggle({
    required String id,
    required String label,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? helpTerm,
  }) => highlightIf(
    id,
    highlightId,
    MenuSwitchItem(
      label: label,
      description: description,
      helpTerm: helpTerm,
      value: value,
      onChanged: onChanged,
    ),
  );
}
