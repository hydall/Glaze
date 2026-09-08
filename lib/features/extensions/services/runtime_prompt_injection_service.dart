import 'dart:convert';

import 'package:flutter_riverpod/legacy.dart';

import '../../../core/llm/history_assembler.dart';

final runtimePromptInjectionProvider =
    StateNotifierProvider<
      RuntimePromptInjectionNotifier,
      Map<String, List<RuntimePromptInjection>>
    >((ref) => RuntimePromptInjectionNotifier());

class RuntimePromptInjection {
  final String id;
  final String content;
  final int depth;
  final String role;

  const RuntimePromptInjection({
    required this.id,
    required this.content,
    required this.depth,
    required this.role,
  });

  PromptMessage toPromptMessage() => PromptMessage(
    role: role,
    content: content,
    blockId: 'runtime_prompt:$id',
    blockName: 'Runtime prompt: $id',
    depth: depth,
    isDepth: true,
  );
}

class RuntimePromptInjectionNotifier
    extends StateNotifier<Map<String, List<RuntimePromptInjection>>> {
  RuntimePromptInjectionNotifier() : super(const {});

  static const maxContentBytes = 64 * 1024;

  RuntimePromptInjection inject({
    required String sessionId,
    required String id,
    required String content,
    int depth = 0,
    String role = 'system',
  }) {
    final normalized = RuntimePromptInjection(
      id: _normalizeId(id),
      content: _normalizeContent(content),
      depth: _normalizeDepth(depth),
      role: _normalizeRole(role),
    );
    final current = state[sessionId] ?? const <RuntimePromptInjection>[];
    final withoutExisting = current.where((item) => item.id != normalized.id);
    state = {
      ...state,
      sessionId: [...withoutExisting, normalized],
    };
    return normalized;
  }

  bool uninject({required String sessionId, required String id}) {
    final normalizedId = _normalizeId(id);
    final current = state[sessionId] ?? const <RuntimePromptInjection>[];
    final next = current.where((item) => item.id != normalizedId).toList();
    if (next.length == current.length) return false;
    if (next.isEmpty) {
      final copy = Map<String, List<RuntimePromptInjection>>.from(state)
        ..remove(sessionId);
      state = copy;
    } else {
      state = {...state, sessionId: next};
    }
    return true;
  }

  List<RuntimePromptInjection> bySession(String sessionId) =>
      List.unmodifiable(state[sessionId] ?? const <RuntimePromptInjection>[]);

  void clearSession(String sessionId) {
    if (!state.containsKey(sessionId)) return;
    final copy = Map<String, List<RuntimePromptInjection>>.from(state)
      ..remove(sessionId);
    state = copy;
  }

  String _normalizeId(String id) {
    final trimmed = id.trim();
    if (trimmed.isEmpty) throw ArgumentError('injectPrompt id is required');
    if (trimmed.length > 128) {
      throw ArgumentError('injectPrompt id must be 128 characters or fewer');
    }
    return trimmed;
  }

  String _normalizeContent(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('injectPrompt content is required');
    }
    if (utf8.encode(trimmed).length > maxContentBytes) {
      throw ArgumentError(
        'injectPrompt content exceeds $maxContentBytes bytes',
      );
    }
    return trimmed;
  }

  int _normalizeDepth(int depth) {
    if (depth < 0) throw ArgumentError('injectPrompt depth must be >= 0');
    if (depth > 100) throw ArgumentError('injectPrompt depth must be <= 100');
    return depth;
  }

  String _normalizeRole(String role) {
    final normalized = role.trim().toLowerCase();
    if (normalized.isEmpty) return 'system';
    if (normalized == 'system' ||
        normalized == 'user' ||
        normalized == 'assistant') {
      return normalized;
    }
    throw ArgumentError('injectPrompt role must be system, user, or assistant');
  }
}
