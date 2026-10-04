import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/studio_config.dart';
import 'db_provider.dart';

/// The Studio profile new sessions inherit, or null when none exists yet.
///
/// The Agents tab in API settings is global — it has no session to scope to —
/// so it reads and writes this profile. Sessions bound to it pick the change
/// up on their next turn.
final studioDefaultProfileProvider = FutureProvider<StudioConfig?>((ref) async {
  final profiles = await ref.watch(studioConfigRepoProvider).getAll();
  return profiles.isEmpty ? null : profiles.first;
});
