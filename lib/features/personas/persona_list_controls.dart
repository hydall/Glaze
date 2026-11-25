import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/persona.dart';
import '../../shared/state/preset_sort.dart';
import '../../shared/widgets/filter_sheet.dart';

/// The Personas list's stored sort, on the same modes and drag order as the
/// Presets list.
final personaSortProvider =
    AsyncNotifierProvider<PresetSortNotifier, PresetSortState>(
      () => PresetSortNotifier(
        modeKey: 'personaListSortMode',
        orderKey: 'personaListManualOrder',
      ),
    );

/// The name a persona is listed under.
String personaListName(Persona persona) =>
    (persona.displayName?.trim().isNotEmpty ?? false)
    ? persona.displayName!.trim()
    : persona.name;

/// [personas] in the order [state] asks for.
List<Persona> sortPersonas(List<Persona> personas, PresetSortState state) =>
    sortPresetItems(
      personas,
      state,
      idOf: (p) => p.id,
      nameOf: personaListName,
      createdAtOf: (p) => p.createdAt,
    );

/// What the filter sheet narrows the Personas list to. Each set flag is a kind
/// of persona to show; none set shows every persona.
class PersonaListFilters {
  /// Bound to a character or a chat.
  final bool bound;
  final bool unbound;

  const PersonaListFilters({this.bound = false, this.unbound = false});

  int get activeCount => (bound ? 1 : 0) + (unbound ? 1 : 0);

  bool get isActive => activeCount > 0;

  bool matches({required bool isBound}) {
    if (!isActive) return true;
    return (bound && isBound) || (unbound && !isBound);
  }
}

/// Filters for the Personas list on the shared [FilterSheet], applied when the
/// sheet closes (the pattern of the Presets list's filter sheet).
class PersonaFilterSheet extends StatefulWidget {
  final PersonaListFilters filters;
  final ValueChanged<PersonaListFilters> onApply;

  const PersonaFilterSheet({
    super.key,
    required this.filters,
    required this.onApply,
  });

  @override
  State<PersonaFilterSheet> createState() => _PersonaFilterSheetState();
}

class _PersonaFilterSheetState extends State<PersonaFilterSheet> {
  late bool _bound = widget.filters.bound;
  late bool _unbound = widget.filters.unbound;

  @override
  void dispose() {
    final apply = widget.onApply;
    final result = PersonaListFilters(bound: _bound, unbound: _unbound);
    Future.microtask(() => apply(result));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FilterSheet(
      title: 'catalog_filters'.tr(),
      fitContent: true,
      sections: [
        FilterGroupSection(
          title: 'header_connections'.tr(),
          rows: [
            FilterToggleSection(
              label: 'persona_filter_bound'.tr(),
              value: _bound,
              onChanged: (v) => setState(() => _bound = v),
            ),
            FilterToggleSection(
              label: 'persona_filter_unbound'.tr(),
              value: _unbound,
              onChanged: (v) => setState(() => _unbound = v),
            ),
          ],
        ),
      ],
    );
  }
}
