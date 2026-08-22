import 'package:flutter_riverpod/legacy.dart';

class StudioHistoryRotationNotice {
  final String sessionId;
  final int droppedMessageCount;

  const StudioHistoryRotationNotice({
    required this.sessionId,
    required this.droppedMessageCount,
  });
}

final studioHistoryRotationProvider =
    StateProvider.family<StudioHistoryRotationNotice?, String>(
      (ref, _) => null,
    );
