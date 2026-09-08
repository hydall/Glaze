import 'dart:async';

import 'package:dio/dio.dart';

import '../../models/block_config.dart';
import '../../models/extension_preset.dart';
import '../../models/info_block.dart';

typedef BlockRunner =
    Future<InfoBlock?> Function({
      required BlockConfig blockConfig,
      required String? previousOutput,
    });

typedef BlockComplete = void Function(InfoBlock block);

class BlockProcessor {
  const BlockProcessor();

  List<BlockConfig> selectBlocks(ExtensionPreset preset, BlockTrigger trigger) {
    return preset.blocks
        .where((b) => b.enabled && b.trigger == trigger && !b.manualOnly)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }

  Future<void> run({
    required ExtensionPreset preset,
    required BlockTrigger trigger,
    required CancelToken cancelToken,
    required BlockRunner runBlock,
    required BlockComplete onBlockComplete,
  }) async {
    final blocks = selectBlocks(preset, trigger);

    if (blocks.isEmpty) {
      return;
    }

    String? previousOutput;
    Future<InfoBlock?>? previousFuture;
    final inFlight = <Future<InfoBlock?>>[];

    for (final blockConfig in blocks) {
      if (cancelToken.isCancelled) break;

      final Future<InfoBlock?> blockFuture;

      if (blockConfig.dependsOnPrevious && previousFuture != null) {
        blockFuture = previousFuture.then((prev) async {
          if (cancelToken.isCancelled) return null;
          return runBlock(
            blockConfig: blockConfig,
            previousOutput: prev?.content,
          );
        });
      } else {
        final capturedPrev = previousOutput;
        blockFuture = runBlock(
          blockConfig: blockConfig,
          previousOutput: capturedPrev,
        );
      }

      if (blockConfig.dependsOnPrevious) {
        final result = await blockFuture;
        if (result != null) {
          previousOutput = result.content;
          onBlockComplete(result);
        }
        previousFuture = null;
      } else {
        previousFuture = blockFuture;
        inFlight.add(blockFuture);
        unawaited(
          blockFuture.then((result) {
            if (result != null) {
              onBlockComplete(result);
            }
          }),
        );
      }
    }

    if (previousFuture != null) {
      await previousFuture;
    }
    if (inFlight.isNotEmpty) {
      await Future.wait(inFlight);
    }
  }
}
