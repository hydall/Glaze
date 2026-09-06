import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
// Pinned via dependency_overrides to keep Windows builds green; see docs/BUILD_NOTES.md.
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';

import '../../core/models/chat_message.dart';
import '../../core/services/chat_import_export.dart';
import '../../core/services/file_export_service.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/persona_resolution.dart';
import '../../core/utils/time_helpers.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../chat_history/chat_history_provider.dart';
import 'chat_session_service.dart';
import 'chat_provider.dart';
import 'services/summary_generation_service.dart';

final chatActionsServiceProvider = Provider<ChatActionsService>((ref) {
  return ChatActionsService(ref);
});

class ChatImportSaveResult {
  const ChatImportSaveResult({
    required this.count,
    required this.sessionId,
    required this.sessionIndex,
  });

  final int count;
  final String? sessionId;
  final int? sessionIndex;
}

class ChatActionsService {
  final Ref _ref;

  ChatActionsService(this._ref);

  Future<String> generateSummary(String charId) async {
    final chatState = _ref.read(chatProvider(charId)).value;
    if (chatState == null || chatState.session == null) {
      throw StateError('No active chat session');
    }

    return _ref
        .read(summaryGenerationServiceProvider)
        .generate(charId: charId, session: chatState.session!);
  }

  Future<String> exportChat(String charId) async {
    final chatState = _ref.read(chatProvider(charId)).value;
    if (chatState == null || chatState.session == null) {
      throw StateError('No active chat session');
    }

    final charRepo = _ref.read(characterRepoProvider);
    final character = await charRepo.getById(charId);
    if (character == null) {
      throw StateError('Character not found');
    }

    final outputDir = await getTemporaryDirectory();

    // The fallback name for user messages that carry no persona of their own.
    // The active persona is the closest thing to who sent them; without it the
    // export named every one of them the literal "User".
    final persona = _ref.read(
      effectivePersonaForChatProvider((
        charId: charId,
        sessionId: chatState.session!.id,
      )),
    );
    final personaName = persona?.name.trim() ?? '';

    final result = await exportChatAsJsonl(
      session: chatState.session!,
      character: character,
      outputDir: outputDir.path,
      userName: personaName.isEmpty ? 'User' : personaName,
    );

    final filename = p.basename(result.filePath);
    return FileExportService.exportFile(
      sourcePath: result.filePath,
      filename: filename,
      subfolder: 'chats',
    );
  }

  Future<void> exportSessionUI(
    BuildContext context, {
    required String charId,
    required String sessionId,
  }) async {
    final notifier = _ref.read(chatProvider(charId).notifier);
    final currentSessionId = _ref.read(chatProvider(charId)).value?.session?.id;
    final needsSwitch = currentSessionId != sessionId;

    if (needsSwitch) {
      final sessions = await notifier.getSessions();
      final target = sessions.where((s) => s.id == sessionId).firstOrNull;
      if (target != null) {
        await notifier.switchSession(target.sessionIndex);
      }
    }

    try {
      final filePath = await exportChat(charId);
      if (filePath.isEmpty) return; // user cancelled the save dialog
      if (context.mounted) {
        GlazeToast.show(context, 'Chat exported to $filePath');
      }
    } on StateError catch (e) {
      if (context.mounted) GlazeToast.show(context, e.message);
    } on Exception catch (e) {
      if (context.mounted) GlazeErrorDialog.show(context, e, prefix: 'Export failed: ');
    } catch (e) {
      if (context.mounted) GlazeErrorDialog.show(context, e, prefix: 'Export failed: ');
    }
  }

  Future<ChatImportSaveResult> importChat(
    String charId,
    String filePath,
  ) async {
    final importResult = await importChatFromJsonl(filePath);
    return importChatFromResult(charId, importResult);
  }

  Future<ChatImportSaveResult> importChatFromResult(
    String charId,
    ChatImportResult importResult,
  ) async {
    if (importResult.messages.isEmpty) {
      return const ChatImportSaveResult(
        count: 0,
        sessionId: null,
        sessionIndex: null,
      );
    }

    final repo = _ref.read(chatRepoProvider);
    final existingSessions = await repo.getByCharacterId(charId);

    int maxIdx = 0;
    for (final s in existingSessions) {
      if (s.sessionIndex > maxIdx) maxIdx = s.sessionIndex;
    }

    final newIdx = maxIdx + 1;
    final newSession = ChatSession(
      id: '${charId}_$newIdx',
      characterId: charId,
      sessionIndex: newIdx,
      messages: importResult.messages,
      updatedAt: currentTimestampSeconds(),
    );

    await repo.put(newSession);
    ChatSessionService.updateCache(newSession);

    final charRepo = _ref.read(characterRepoProvider);
    final character = await charRepo.getById(charId);
    if (character != null) {
      await charRepo.put(character.copyWith(currentSessionIndex: newIdx));
    }

    _ref.invalidate(chatProvider(charId));
    _ref.invalidate(chatHistoryProvider);

    return ChatImportSaveResult(
      count: importResult.messages.length,
      sessionId: newSession.id,
      sessionIndex: newIdx,
    );
  }
}
