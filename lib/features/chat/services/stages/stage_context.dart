import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../abort_handler.dart';
import '../../chat_state.dart';

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
}
