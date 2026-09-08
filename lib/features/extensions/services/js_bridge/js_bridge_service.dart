import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/db/repositories/character_repo.dart';
import '../../../../core/db/repositories/chat_repo.dart';
import '../../../../core/db/repositories/global_variables_repo.dart';
import 'handlers/audio_handler.dart';
import 'handlers/command_handler.dart';
import 'handlers/generation_handler.dart';
import 'handlers/prompt_injection_handler.dart';
import 'handlers/toast_handler.dart';
import 'handlers/variables_handler.dart';
import 'js_bridge_context.dart';
import 'js_bridge_method_registry.dart';

export 'js_bridge_context.dart'
    show
        ExecuteCommandHandler,
        GenerateTextHandler,
        InjectPromptHandler,
        MessageVariablesAccessor,
        PermissionCheck,
        PlayAudioHandler,
        ShowToastHandler,
        TriggerGenerationHandlerFn,
        UninjectPromptHandler;
export 'js_bridge_method_registry.dart'
    show
        JsBridgeHostProfile,
        JsBridgeMethodDefinition,
        JsBridgeMethodRegistry,
        JsBridgeOperation;

class JsBridgeService {
  final ChatRepo _chatRepo;
  final CharacterRepo _characterRepo;
  final GlobalVariablesRepo _globalVariablesRepo;
  final MessageVariablesAccessor _messageVariables;
  final String? Function() _currentSessionId;
  final String? Function() _currentCharacterId;
  final GenerateTextHandler _generateText;
  final InjectPromptHandler _injectPrompt;
  final UninjectPromptHandler _uninjectPrompt;
  final TriggerGenerationHandlerFn _triggerGeneration;
  final PermissionCheck _permissionCheck;
  final PlayAudioHandler _playAudio;
  final ExecuteCommandHandler _executeCommand;
  final ShowToastHandler _showToast;

  final VariablesHandler _variablesHandler;
  final GenerationHandler _generationHandler;
  final PromptInjectionHandler _promptInjectionHandler;
  final AudioHandler _audioHandler;
  final CommandHandler _commandHandler;
  final ToastHandler _toastHandler;

  JsBridgeService({
    required ChatRepo chatRepo,
    required CharacterRepo characterRepo,
    required GlobalVariablesRepo globalVariablesRepo,
    required MessageVariablesAccessor messageVariables,
    required String? Function() currentSessionId,
    required String? Function() currentCharacterId,
    required GenerateTextHandler generateText,
    required InjectPromptHandler injectPrompt,
    required UninjectPromptHandler uninjectPrompt,
    required TriggerGenerationHandlerFn triggerGeneration,
    required PermissionCheck permissionCheck,
    required PlayAudioHandler playAudio,
    required ExecuteCommandHandler executeCommand,
    required ShowToastHandler showToast,
  }) : this._(
         chatRepo,
         characterRepo,
         globalVariablesRepo,
         messageVariables,
         currentSessionId,
         currentCharacterId,
         generateText,
         injectPrompt,
         uninjectPrompt,
         triggerGeneration,
         permissionCheck,
         playAudio,
         executeCommand,
         showToast,
         const VariablesHandler(),
         const GenerationHandler(),
         const PromptInjectionHandler(),
         const AudioHandler(),
         const CommandHandler(),
         const ToastHandler(),
       );

  const JsBridgeService._(
    this._chatRepo,
    this._characterRepo,
    this._globalVariablesRepo,
    this._messageVariables,
    this._currentSessionId,
    this._currentCharacterId,
    this._generateText,
    this._injectPrompt,
    this._uninjectPrompt,
    this._triggerGeneration,
    this._permissionCheck,
    this._playAudio,
    this._executeCommand,
    this._showToast,
    this._variablesHandler,
    this._generationHandler,
    this._promptInjectionHandler,
    this._audioHandler,
    this._commandHandler,
    this._toastHandler,
  );

  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> request) async {
    final method = request['method'] as String? ?? '';
    final params = asBridgeMap(request['params']);

    try {
      final result = await _handle(
        method,
        params,
        asBridgeMap(request['context']),
      );
      return {'ok': true, 'result': result};
    } catch (e, st) {
      debugPrint('[JsBridge] $method failed: $e\n$st');
      return {
        'ok': false,
        'error': {
          'code': e is UnsupportedError
              ? 'unsupported_method'
              : e is ArgumentError
              ? 'invalid_request'
              : 'bridge_error',
          'message': e.toString(),
        },
      };
    }
  }

  FutureOr<dynamic> _handle(
    String method,
    Map<String, dynamic> params,
    Map<String, dynamic> context,
  ) {
    final definition = JsBridgeMethodRegistry.lookup(method);
    if (definition == null) {
      throw UnsupportedError('Unknown glaze method "$method"');
    }

    final bridge = JsBridgeContext(
      params: params,
      context: context,
      chatRepo: _chatRepo,
      characterRepo: _characterRepo,
      globalVariablesRepo: _globalVariablesRepo,
      messageVariables: _messageVariables,
      currentSessionId: _currentSessionId,
      currentCharacterId: _currentCharacterId,
      generateText: _generateText,
      injectPrompt: _injectPrompt,
      uninjectPrompt: _uninjectPrompt,
      triggerGeneration: _triggerGeneration,
      permissionCheck: _permissionCheck,
      playAudio: _playAudio,
      executeCommand: _executeCommand,
      showToast: _showToast,
    );
    bridge.requireCapability(definition.capabilityFor(params));

    switch (definition.operation) {
      case JsBridgeOperation.showToast:
        return _toastHandler.showToast(bridge);
      case JsBridgeOperation.getVariables:
        return _variablesHandler.getVariables(bridge);
      case JsBridgeOperation.setVariables:
        return _variablesHandler.setVariables(bridge);
      case JsBridgeOperation.deleteVariable:
        return _variablesHandler.deleteVariable(bridge);
      case JsBridgeOperation.executeCommand:
        return _commandHandler.executeCommand(bridge);
      case JsBridgeOperation.triggerGeneration:
        return _generationHandler.triggerGeneration(bridge);
      case JsBridgeOperation.playAudio:
        return _audioHandler.playAudio(bridge);
      case JsBridgeOperation.injectPrompt:
        return _promptInjectionHandler.injectPrompt(bridge);
      case JsBridgeOperation.uninjectPrompt:
        return _promptInjectionHandler.uninjectPrompt(bridge);
      case JsBridgeOperation.generateText:
        return _generationHandler.generateText(bridge);
    }
  }
}
