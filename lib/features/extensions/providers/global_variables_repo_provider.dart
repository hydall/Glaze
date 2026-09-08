import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/global_variables_repo.dart';

/// Async-resolved [GlobalVariablesRepo]. The repo itself does not
/// expose reactive state, so we just expose the singleton instance via
/// `ref.read` / `ref.watch(future)`.
final globalVariablesRepoProvider =
    FutureProvider<GlobalVariablesRepo>((ref) async {
  return GlobalVariablesRepo.create();
});
