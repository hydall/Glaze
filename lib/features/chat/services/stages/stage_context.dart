import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/llm/generation_phase.dart';
import '../../abort_handler.dart';
import '../../chat_state.dart';
import '../../state/generation_phase_provider.dart';

/// Shared dependencies passed to every pipeline stage. Encapsulates the
/// Ref, character id, abort handler, and state accessors that were
/// previously constructor params of [GenerationPipeline].
class StageContext {
  final Ref ref;
  final String charId;
  final AbortHandler abortHandler;
  final void Function(AsyncValue<ChatState>) setState;
  final AsyncValue<ChatState> Function() getState;

  const StageContext({
    required this.ref,
    required this.charId,
    required this.abortHandler,
    required this.setState,
    required this.getState,
  });

  /// Publishes the live generation phase for the typing bubble. Scoped to
  /// [genId] so a stale stage settling late cannot relabel the run that
  /// replaced it.
  void setPhase(GenerationPhase phase, {required int genId}) {
    if (!ref.mounted || !abortHandler.isCurrentGen(genId)) return;
    setGenerationPhase(ref, charId, phase);
  }
}
