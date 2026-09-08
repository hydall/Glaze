import 'package:freezed_annotation/freezed_annotation.dart';

import 'block_run_status.dart';

part 'info_block.freezed.dart';
part 'info_block.g.dart';

@freezed
abstract class InfoBlock with _$InfoBlock {
  const factory InfoBlock({
    required String id,
    required String sessionId,
    required String messageId,
    @Default(0) int swipeId,
    @Default(-1) int agentSwipeId,
    required String blockId,
    required String blockName,
    required String blockType,
    required String content,
    required int createdAt,
    @Default(0) int order,
    @Default(BlockRunStatus.done) BlockRunStatus status,
  }) = _InfoBlock;

  factory InfoBlock.fromJson(Map<String, dynamic> json) =>
      _$InfoBlockFromJson(json);
}
