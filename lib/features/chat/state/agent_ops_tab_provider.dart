import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/state/shared_prefs_provider.dart';

/// SharedPreferences key for the remembered Agent Ops tab.
const agentOpsTabKey = 'agentOpsTab';

/// Which tab of the Agent Ops sheet was open last.
///
/// Agent Ops is a working surface: someone recovering a writer chain opens it,
/// closes it to look at the chat, and opens it again — landing back on
/// Reconciler every time makes that a three-tap loop. The index is persisted,
/// so it survives a restart too, and hydrated at startup
/// ([loadAgentOpsTab]) rather than on first open, so the sheet never opens on
/// one tab and then jumps to another.
///
/// An index the current build no longer has is clamped by the sheet, not here:
/// this provider does not know how many tabs there are.
final agentOpsTabProvider = StateProvider<int>((ref) => 0);

Future<void> loadAgentOpsTab(WidgetRef ref) async {
  final prefs = await ref.read(sharedPreferencesProvider.future);
  final stored = prefs.getInt(agentOpsTabKey);
  if (stored == null || stored < 0) return;
  ref.read(agentOpsTabProvider.notifier).state = stored;
}

Future<void> setAgentOpsTab(WidgetRef ref, int index) async {
  if (ref.read(agentOpsTabProvider) == index) return;
  ref.read(agentOpsTabProvider.notifier).state = index;
  final prefs = await ref.read(sharedPreferencesProvider.future);
  await prefs.setInt(agentOpsTabKey, index);
}
