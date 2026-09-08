import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/global_variables_repo.dart';
import 'package:glaze_flutter/features/extensions/services/js_bridge_service.dart';
import 'package:glaze_flutter/features/extensions/services/js_bridge/js_bridge_context.dart';
import 'package:glaze_flutter/features/extensions/state/message_variables_notifier.dart';

/// Fully wired inert ports for JS bridge unit tests.
class TestJsBridge {
  static JsBridgeContext context({
    required Map<String, dynamic> params,
    required Map<String, dynamic> context,
    String? Function()? currentSessionId,
    String? Function()? currentCharacterId,
    GenerateTextHandler? generateText,
    InjectPromptHandler? injectPrompt,
    UninjectPromptHandler? uninjectPrompt,
    TriggerGenerationHandlerFn? triggerGeneration,
    PermissionCheck? permissionCheck,
    PlayAudioHandler? playAudio,
    ExecuteCommandHandler? executeCommand,
    ShowToastHandler? showToast,
  }) {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    return JsBridgeContext(
      params: params,
      context: context,
      chatRepo: ChatRepo(db),
      characterRepo: CharacterRepo(db),
      globalVariablesRepo: GlobalVariablesRepo.withPrefsLoader(
        SharedPreferences.getInstance,
      ),
      messageVariables: MessageVariablesNotifier.new,
      currentSessionId: currentSessionId ?? () => null,
      currentCharacterId: currentCharacterId ?? () => null,
      generateText:
          generateText ?? (_, _, _) => throw UnsupportedError('unwired'),
      injectPrompt:
          injectPrompt ?? (_, _, _, _) => throw UnsupportedError('unwired'),
      uninjectPrompt:
          uninjectPrompt ?? (_, _) => throw UnsupportedError('unwired'),
      triggerGeneration:
          triggerGeneration ?? (_, _) => throw UnsupportedError('unwired'),
      permissionCheck: permissionCheck ?? (_) => false,
      playAudio: playAudio ?? (_, _) => throw UnsupportedError('unwired'),
      executeCommand:
          executeCommand ?? (_, _, _) => throw UnsupportedError('unwired'),
      showToast: showToast ?? (_, _) {},
    );
  }

  static JsBridgeService create({
    ChatRepo? chatRepo,
    CharacterRepo? characterRepo,
    GlobalVariablesRepo? globalVariablesRepo,
    MessageVariablesAccessor? messageVariables,
    String? Function()? currentSessionId,
    String? Function()? currentCharacterId,
    GenerateTextHandler? generateText,
    InjectPromptHandler? injectPrompt,
    UninjectPromptHandler? uninjectPrompt,
    TriggerGenerationHandlerFn? triggerGeneration,
    PermissionCheck? permissionCheck,
    PlayAudioHandler? playAudio,
    ExecuteCommandHandler? executeCommand,
    ShowToastHandler? showToast,
  }) {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    TestWidgetsFlutterBinding.ensureInitialized();
    if (globalVariablesRepo == null) {
      SharedPreferences.setMockInitialValues({});
    }
    return JsBridgeService(
      chatRepo: chatRepo ?? ChatRepo(db),
      characterRepo: characterRepo ?? CharacterRepo(db),
      globalVariablesRepo:
          globalVariablesRepo ??
          GlobalVariablesRepo.withPrefsLoader(SharedPreferences.getInstance),
      messageVariables: messageVariables ?? MessageVariablesNotifier.new,
      currentSessionId: currentSessionId ?? () => null,
      currentCharacterId: currentCharacterId ?? () => null,
      generateText:
          generateText ?? (_, _, _) => throw UnsupportedError('unwired'),
      injectPrompt:
          injectPrompt ?? (_, _, _, _) => throw UnsupportedError('unwired'),
      uninjectPrompt:
          uninjectPrompt ?? (_, _) => throw UnsupportedError('unwired'),
      triggerGeneration:
          triggerGeneration ?? (_, _) => throw UnsupportedError('unwired'),
      permissionCheck: permissionCheck ?? (_) => false,
      playAudio: playAudio ?? (_, _) => throw UnsupportedError('unwired'),
      executeCommand:
          executeCommand ?? (_, _, _) => throw UnsupportedError('unwired'),
      showToast: showToast ?? (_, _) {},
    );
  }
}
