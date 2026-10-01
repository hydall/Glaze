import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/transport/chat_transport_request.dart';
import '../../../core/llm/transport/llm_protocol.dart';
import '../../../core/llm/transport/transport_factory.dart';
import '../../settings/api_list_provider.dart';
import 'vn_script.dart';

/// Why a game could not be generated.
enum VnGenerationFailure { noApi, incompleteApi, noScenes }

class VnGenerationException implements Exception {
  const VnGenerationException(this.failure);

  final VnGenerationFailure failure;

  @override
  String toString() => 'VnGenerationException($failure)';
}

/// Asks the active API connection for a whole game script in one request.
class VnGeneratorService {
  VnGeneratorService(this._ref);

  final Ref _ref;

  static const Duration _timeout = Duration(minutes: 3);

  Future<String> generate({
    required String premise,
    required String language,
    CancelToken? cancelToken,
  }) async {
    await _ref.read(apiListProvider.future);
    final apiConfig = _ref.read(activeApiConfigProvider);
    if (apiConfig == null) {
      throw const VnGenerationException(VnGenerationFailure.noApi);
    }
    final endpointRequired = apiConfig.protocol != LlmProtocol.openrouter;
    if ((endpointRequired && apiConfig.endpoint.isEmpty) ||
        apiConfig.model.isEmpty) {
      throw const VnGenerationException(VnGenerationFailure.incompleteApi);
    }

    final spec = await rootBundle.loadString(kVnModelSpecAsset);
    final token = cancelToken ?? CancelToken();
    final completer = Completer<String>();
    unawaited(
      pickChatTransport(apiConfig.protocol).stream(
        request: ChatTransportRequest.fromApiConfig(
          apiConfig,
          messages: buildVnGenerationMessages(
            spec: spec,
            premise: premise,
            language: language,
          ),
          stream: false,
        ),
        cancelToken: token,
        onComplete: (text, _, {rawResponseJson}) {
          if (!completer.isCompleted) completer.complete(text);
        },
        onError: (error) {
          if (!completer.isCompleted) completer.completeError(error);
        },
      ),
    );
    final reply = await completer.future.timeout(
      _timeout,
      onTimeout: () {
        token.cancel('VN generation timed out');
        throw TimeoutException('VN generation timed out', _timeout);
      },
    );
    final script = extractVnScript(reply);
    if (script == null) {
      throw const VnGenerationException(VnGenerationFailure.noScenes);
    }
    return script;
  }
}

final vnGeneratorServiceProvider = Provider<VnGeneratorService>(
  VnGeneratorService.new,
);
