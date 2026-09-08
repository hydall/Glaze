import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/active_studio_preset_provider.dart';
import '../../core/state/db_provider.dart';
import '../../core/utils/time_helpers.dart';
import 'services/studio_preset_workflow_service.dart';

final studioPresetWorkflowServiceProvider =
    Provider<StudioPresetWorkflowService>(
      (ref) => StudioPresetWorkflowService(
        ref.watch(studioPresetRepoProvider),
        () => ref.read(activeStudioPresetProvider.future),
        (presetId) =>
            ref.read(activeStudioPresetProvider.notifier).set(presetId),
        currentTimestampSeconds,
      ),
    );
