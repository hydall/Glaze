import 'package:dio/dio.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';

/// Resolves the dedicated card-rewrite model slot to an [AuxApiConfig].
/// Implementations must be fail-explicit: throw when the slot is unconfigured.
/// There is NO silent fallback to the active chat config.
typedef CardRewriteModelResolver = Future<AuxApiConfig> Function();

/// The writer-lane transport seam. Production delegates to
/// [AuxLlmClient.callOnceWithLog]; tests fake it at this boundary.
typedef CardRewriteLlmExecutor =
    Future<AuxCallOutcome> Function({
      required AuxApiConfig config,
      required String prompt,
      required int maxTokens,
      required double temperature,
      required int timeoutMs,
      CancelToken? cancelToken,
      LlmCaptureContext? captureContext,
    });
