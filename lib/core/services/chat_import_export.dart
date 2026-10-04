import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/chat_message.dart';
import '../models/character.dart';
import 'file_export_result.dart';

@Deprecated('Use FileExportResult instead.')
typedef ChatExportResult = FileExportResult;

class ChatImportResult {
  final List<ChatMessage> messages;
  final String? userName;
  ChatImportResult({required this.messages, this.userName});
}

Future<FileExportResult> exportChatAsJsonl({
  required ChatSession session,
  required Character character,
  required String outputDir,
  String userName = 'User',
}) async {
  final lines = <String>[];

  final metadata = {
    'user_name': userName,
    'character_name': character.name,
    'create_date': _formatSTDate(DateTime.now()),
    'chat_metadata': {
      'exported_from': 'Glaze',
      'import_date': DateTime.now().millisecondsSinceEpoch,
    },
  };
  lines.add(jsonEncode(metadata));

  for (final msg in session.messages) {
    final isUser = msg.role == 'user';
    // A user message names the persona it was actually sent as; [userName] is
    // only the fallback for the ones that carry none (chats written before
    // messages stored a persona, or an import that had nothing to store).
    final messagePersona = msg.personaName?.trim();
    final name = isUser
        ? (messagePersona == null || messagePersona.isEmpty
              ? userName
              : messagePersona)
        : character.name;

    // SillyTavern (and every reader built on its format, Tavo included) has
    // no hidden flag of its own: `/hide` just sets `is_system` on the message
    // and the prompt builder drops every `is_system` line. So `is_system` is
    // where our [ChatMessage.isHidden] has to land, alongside the messages
    // that are genuinely system-role. Exporting hidden messages at all is the
    // point — they used to be skipped outright, which lost them silently.
    final isSystem = msg.isHidden || msg.role == 'system';

    final stMsg = <String, dynamic>{
      'name': name,
      'is_user': isUser,
      'is_system': isSystem,
      'send_date': _formatSTDate(
        DateTime.fromMillisecondsSinceEpoch(msg.timestamp ?? 0),
      ),
      'mes': msg.content,
      'swipe_id': msg.swipeId,
      'swipes': msg.swipes,
      'extra': <String, dynamic>{},
    };

    if (msg.reasoning != null) {
      stMsg['extra']!['reasoning'] = msg.reasoning;
    }
    if (msg.id.isNotEmpty) {
      stMsg['extra']!['glazeMessageId'] = msg.id;
    }
    // `is_system` flattens two distinct Glaze states (hidden, and system-role)
    // into one flag, so a Glaze -> Glaze round trip needs both spelled out to
    // come back unchanged. Foreign files carry neither and fall back to the
    // SillyTavern reading of `is_system` on import.
    if (isSystem) {
      stMsg['extra']!['glazeHidden'] = msg.isHidden;
      stMsg['extra']!['glazeRole'] = msg.role;
    }

    if (msg.swipes.isNotEmpty && msg.swipes.length > 1) {
      stMsg['swipe_info'] = msg.swipes.map((_) => <String, dynamic>{}).toList();
    }

    lines.add(jsonEncode(stMsg));
  }

  final fileContent = lines.join('\n');
  final safeName = character.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final dateStr = DateTime.now()
      .toIso8601String()
      .replaceAll(RegExp(r'[:T]'), '-')
      .split('.')
      .first;
  final filename = '$safeName - $dateStr.jsonl';
  final filePath = p.join(outputDir, filename);

  await File(filePath).writeAsString(fileContent);
  return FileExportResult(filePath: filePath);
}

Future<ChatImportResult> importChatFromJsonl(String filePath) async {
  final file = File(filePath);
  if (!await file.exists()) {
    throw FileSystemException('File not found', filePath);
  }
  final content = await file.readAsString();
  if (content.trim().isEmpty) {
    throw StateError('File is empty: $filePath');
  }
  return importChatFromJsonlString(content);
}

ChatImportResult importChatFromJsonlString(String content) {
  final lines = content.split('\n');
  final messages = <ChatMessage>[];
  String? userName;

  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    Map<String, dynamic> obj;
    try {
      obj = jsonDecode(trimmed) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }

    if (obj.containsKey('chat_metadata')) {
      userName = obj['user_name'] as String?;
      continue;
    }

    final msg = convertStMessage(obj, messages.length);
    if (msg == null) continue;

    messages.add(msg);
  }

  return ChatImportResult(messages: messages, userName: userName);
}

ChatMessage? convertStMessage(Map<String, dynamic> obj, int index) {
  try {
    final isUser = _parseBool(obj['is_user']) ?? false;
    final isSystem = _parseBool(obj['is_system']) ?? false;
    final text = (obj['mes'] as String?) ?? '';
    final sendDate = obj['send_date'] as String?;

    final extra = obj['extra'];
    final extraMap = extra is Map<String, dynamic>
        ? extra
        : const <String, dynamic>{};
    // Written by our own export when `is_system` had to carry two states at
    // once. Present only on Glaze-written files, and authoritative there.
    final glazeRole = extraMap['glazeRole'] as String?;
    final glazeHidden = extraMap['glazeHidden'];

    String role;
    if (glazeRole != null && glazeRole.isNotEmpty) {
      role = glazeRole;
    } else if (isUser) {
      // `is_user` outranks `is_system`: SillyTavern leaves `is_user` alone when
      // it hides a message, so both flags together is a hidden user message,
      // never a system one (its own system lines are always `is_user: false`).
      role = 'user';
    } else if (isSystem) {
      role = 'system';
    } else {
      role = 'assistant';
    }

    // In the SillyTavern format `is_system` means "kept out of the prompt" —
    // that is exactly [ChatMessage.isHidden], not our system role, which we do
    // send. So a foreign `is_system` line imports as hidden; without this an
    // ST/Tavo hidden message came back visible *and* went to the model.
    final isHidden = glazeHidden is bool ? glazeHidden : isSystem;

    if (text.trim().isEmpty) return null;

    final timestamp = _parseSTDate(sendDate);

    final swipesRaw = obj['swipes'];
    final swipes = swipesRaw is List
        ? swipesRaw.map((s) => s.toString()).toList()
        : <String>[];
    final swipeId = _parseInt(obj['swipe_id']) ?? 0;

    final reasoning = extraMap['reasoning'] as String?;

    return ChatMessage(
      id:
          extraMap['glazeMessageId'] as String? ??
          'imp_${DateTime.now().millisecondsSinceEpoch}_$index',
      role: role,
      content: text,
      timestamp: timestamp,
      swipes: swipes,
      swipeId: swipeId,
      reasoning: reasoning,
      isHidden: isHidden,
    );
  } catch (_) {
    return null;
  }
}

bool? _parseBool(dynamic value) {
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true';
  if (value is int) return value != 0;
  return null;
}

int? _parseInt(dynamic value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  if (value is double) return value.toInt();
  return null;
}

int _parseSTDate(String? dateStr) {
  if (dateStr == null) return DateTime.now().millisecondsSinceEpoch;
  try {
    final parsed = DateTime.tryParse(dateStr);
    if (parsed != null) return parsed.millisecondsSinceEpoch;
  } catch (_) {}
  return DateTime.now().millisecondsSinceEpoch;
}

String _formatSTDate(DateTime dt) {
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${pad(dt.month)}-${pad(dt.day)} ${pad(dt.hour)}:${pad(dt.minute)}:${pad(dt.second)}';
}
