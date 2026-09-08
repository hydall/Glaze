import 'package:dio/dio.dart';

import '../db/repositories/summary_repo.dart';
import '../models/api_config.dart';
import '../models/chat_message.dart';
import 'sse_client.dart';

const _defaultSummaryPrompt =
    'Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n';

class SummaryService {
  final SummaryRepo _repo;
  final Dio _dio;

  SummaryService(this._repo, [Dio? dio]) : _dio = dio ?? Dio();

  Future<String?> getSummary(String sessionId) async {
    final row = await _repo.get(sessionId);
    if (row == null || !row.enabled) return null;
    return row.content;
  }

  Future<String?> getSummaryContent(String sessionId) async {
    final row = await _repo.get(sessionId);
    return row?.content;
  }

  Future<bool> isSummaryEnabled(String sessionId) async {
    final row = await _repo.get(sessionId);
    return row?.enabled ?? true;
  }

  /// Persists a manually-edited summary. Empty content clears it. This is the
  /// same store the prompt builder reads ([getSummary]), so manual edits are
  /// injected exactly like generated ones.
  Future<void> setSummary({
    required String sessionId,
    required String content,
    required int messageCount,
  }) async {
    final trimmed = content.trim();
    await _repo.put(
      sessionId: sessionId,
      content: trimmed,
      messageCount: messageCount,
    );
  }

  Future<void> setSummaryEnabled({
    required String sessionId,
    required bool enabled,
  }) {
    return _repo.setEnabled(sessionId: sessionId, enabled: enabled);
  }

  Future<int> getSummaryMessageCount(String sessionId) async {
    final row = await _repo.get(sessionId);
    return row?.messageCount ?? 0;
  }

  Future<String> generateSummary({
    required String sessionId,
    required List<ChatMessage> history,
    required ApiConfig apiConfig,
    String? customPrompt,
  }) async {
    if (apiConfig.endpoint.isEmpty) {
      throw Exception('API endpoint not configured');
    }
    if (apiConfig.model.isEmpty) {
      throw Exception('API model not configured');
    }

    final historyText = _formatHistory(history);
    final template = customPrompt ?? _defaultSummaryPrompt;
    String prompt;
    if (template.contains('{{history}}')) {
      prompt = template.replaceAll('{{history}}', historyText);
    } else {
      prompt = '$template\n\n$historyText';
    }

    final uri = _buildUrl(apiConfig.endpoint);
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (apiConfig.apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${apiConfig.apiKey}';
    }

    final response = await _dio.post<Map<String, dynamic>>(
      uri,
      data: {
        'model': apiConfig.model,
        'messages': [
          {'role': 'system', 'content': prompt},
        ],
        'max_tokens': 1024,
        'temperature': 0.3,
      },
      options: Options(headers: headers),
    );

    final data = response.data;
    if (data == null) throw Exception('Empty API response');

    final choices = data['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      throw Exception('No choices in API response');
    }
    final content = choices[0]['message']?['content'] as String? ?? '';

    await _repo.put(
      sessionId: sessionId,
      content: content.trim(),
      messageCount: history.length,
      prompt: customPrompt,
    );

    return content.trim();
  }

  Future<void> deleteSummary(String sessionId) async {
    await _repo.deleteBySessionId(sessionId);
  }

  bool needsRegeneration(int currentMessageCount, int? savedCount) {
    if (savedCount == null || savedCount == 0) return true;
    final threshold = (savedCount * 0.3).ceil();
    return currentMessageCount - savedCount >= threshold && currentMessageCount > 10;
  }

  String _formatHistory(List<ChatMessage> messages) {
    final buf = StringBuffer();
    for (final msg in messages) {
      if (msg.role == 'user' || msg.role == 'assistant') {
        final speaker = msg.role == 'user' ? 'User' : 'Character';
        buf.writeln('$speaker: ${msg.content}');
      }
    }
    return buf.toString();
  }

  String _buildUrl(String endpoint) {
    return SseClient.buildChatUrl(endpoint);
  }
}
