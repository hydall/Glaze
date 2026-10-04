import 'dart:convert';

import '../../models/chat_message.dart';
import '../../utils/cast_helpers.dart';
import '../app_db.dart';

final class CardEvolutionSelectedChatEvidence {
  const CardEvolutionSelectedChatEvidence._({
    required this.chatHistoryHash,
    required this.effectiveCanonIdentity,
    required this.entries,
  });

  final String chatHistoryHash;
  final String effectiveCanonIdentity;
  final List<CardEvolutionSelectedChatEntry> entries;

  static CardEvolutionSelectedChatEvidence? tryParse(String encoded) {
    try {
      final root = jsonDecode(encoded);
      if (root is! Map || root['contractVersion'] != 8) return null;
      final chatHistoryHash = root['chatHistoryHash'];
      final effectiveCanonIdentity = root['effectiveCanonIdentity'];
      final history = root['chatHistory'];
      if (chatHistoryHash is! String ||
          chatHistoryHash.isEmpty ||
          effectiveCanonIdentity is! String ||
          effectiveCanonIdentity.isEmpty ||
          history is! List ||
          history.isEmpty) {
        return null;
      }

      final entries = <CardEvolutionSelectedChatEntry>[];
      final ids = <String>{};
      final canonicalHistory = <Map<String, Object?>>[];
      for (final raw in history) {
        if (raw is! Map) return null;
        final messageId = raw['messageId'];
        final role = raw['role'];
        final swipeId = raw['swipeId'];
        final agentSwipeId = raw['agentSwipeId'];
        final content = raw['content'];
        final contentHash = raw['contentHash'];
        if (messageId is! String ||
            messageId.isEmpty ||
            !ids.add(messageId) ||
            (role != 'user' && role != 'assistant') ||
            swipeId is! int ||
            swipeId < 0 ||
            agentSwipeId is! int ||
            agentSwipeId < 0 ||
            content is! String ||
            contentHash is! String ||
            contentHash.isEmpty ||
            computeHash(content) != contentHash) {
          return null;
        }
        entries.add(
          CardEvolutionSelectedChatEntry(
            messageId: messageId,
            role: role as String,
            swipeId: swipeId,
            agentSwipeId: agentSwipeId,
            content: content,
            contentHash: contentHash,
          ),
        );
        canonicalHistory.add({
          'messageId': messageId,
          'role': role,
          'swipeId': swipeId,
          'agentSwipeId': agentSwipeId,
          'content': content,
          'contentHash': contentHash,
        });
      }
      if (computeHash(_canonicalJson(canonicalHistory)) != chatHistoryHash) {
        return null;
      }
      return CardEvolutionSelectedChatEvidence._(
        chatHistoryHash: chatHistoryHash,
        effectiveCanonIdentity: effectiveCanonIdentity,
        entries: List.unmodifiable(entries),
      );
    } catch (_) {
      return null;
    }
  }

  bool referencesAny(Set<String> messageIds) =>
      entries.any((entry) => messageIds.contains(entry.messageId));

  bool matchesMessagesJson(String messagesJson) {
    try {
      final decoded = jsonDecode(messagesJson);
      if (decoded is! List) return false;
      final messages = decoded
          .whereType<Map<dynamic, dynamic>>()
          .map((raw) => ChatMessage.fromJson(Map<String, dynamic>.from(raw)))
          .toList(growable: false);
      var previousIndex = -1;
      for (final entry in entries) {
        final index = messages.indexWhere(
          (message) => message.id == entry.messageId,
        );
        if (index <= previousIndex) return false;
        final message = messages[index];
        if (message.role != entry.role ||
            message.swipeId != entry.swipeId ||
            message.agentSwipeId != entry.agentSwipeId ||
            message.content != entry.content ||
            computeHash(message.content) != entry.contentHash) {
          return false;
        }
        previousIndex = index;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  bool validatesProposal(
    CardEvolutionProposalRunRow proposal, {
    required String jobId,
    required String sessionId,
    required String characterId,
    required String messagesJson,
  }) =>
      proposal.rewriteJobId == jobId &&
      proposal.sessionId == sessionId &&
      proposal.characterId == characterId &&
      computeHash(proposal.selectedInputJson) == proposal.inputHash &&
      chatHistoryHash == proposal.chatHistoryHash &&
      effectiveCanonIdentity == proposal.effectiveCanonIdentity &&
      matchesMessagesJson(messagesJson);
}

final class CardEvolutionSelectedChatEntry {
  const CardEvolutionSelectedChatEntry({
    required this.messageId,
    required this.role,
    required this.swipeId,
    required this.agentSwipeId,
    required this.content,
    required this.contentHash,
  });

  final String messageId;
  final String role;
  final int swipeId;
  final int agentSwipeId;
  final String content;
  final String contentHash;
}

String _canonicalJson(Object? value) {
  Object? canonical(Object? item) {
    if (item is Map) {
      final keys = item.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: canonical(item[key])};
    }
    if (item is Iterable) return item.map(canonical).toList();
    return item;
  }

  return jsonEncode(canonical(value));
}
