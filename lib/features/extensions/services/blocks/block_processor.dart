import 'dart:async';

import 'package:dio/dio.dart';

import '../../models/block_config.dart';
import '../../models/extension_preset.dart';
import '../../models/info_block.dart';
import 'block_trigger_rules.dart';

typedef BlockRunner =
    Future<InfoBlock?> Function({
      required BlockConfig blockConfig,
      required String? previousOutput,
    });

typedef BlockComplete = void Function(InfoBlock block);

class BlockProcessor {
  const BlockProcessor();

  /// The blocks that run automatically on [trigger], in chain order.
  /// [where] narrows them further, e.g. to the ones whose keyword or period
  /// matches the triggering message.
  List<BlockConfig> selectBlocks(
    ExtensionPreset preset,
    BlockTrigger trigger, {
    bool Function(BlockConfig block)? where,
  }) {
    return preset.blocks
        .where(
          (b) =>
              b.enabled &&
              b.runsOn(trigger) &&
              !b.manualOnly &&
              b.type.isRunnable &&
              (where?.call(b) ?? true),
        )
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }

  Future<void> run({
    required ExtensionPreset preset,
    required BlockTrigger trigger,
    required CancelToken cancelToken,
    required BlockRunner runBlock,
    required BlockComplete onBlockComplete,
    bool Function(BlockConfig block)? where,
    void Function(Future<InfoBlock?> run)? onBackgroundStarted,
  }) async {
    final blocks = selectBlocks(preset, trigger, where: where);

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
        // A background block keeps running after the chain returns, so the
        // run reads as finished while it works, as in the original. A block
        // that depends on it still waits for it.
        if (blockConfig.background) {
          onBackgroundStarted?.call(blockFuture);
        } else {
          inFlight.add(blockFuture);
        }
        unawaited(
          blockFuture.then((result) {
            if (result != null) {
              onBlockComplete(result);
            }
          }),
        );
      }
    }

    if (inFlight.isNotEmpty) {
      await Future.wait(inFlight);
    }
  }
}
