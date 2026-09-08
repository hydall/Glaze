import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/shared_prefs_provider.dart';

class QuickReply {
  /// Stable id. The reserved id "continue" triggers continueMessage()
  /// when tapped instead of sending [text].
  final String id;
  final String label;
  final String text;

  const QuickReply({required this.id, required this.label, required this.text});

  bool get isContinueAction => id == 'continue';

  QuickReply copyWith({String? label, String? text}) {
    return QuickReply(
      id: id,
      label: label ?? this.label,
      text: text ?? this.text,
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'text': text};

  factory QuickReply.fromJson(Map<String, dynamic> json) => QuickReply(
    id: json['id'] as String,
    label: json['label'] as String? ?? '',
    text: json['text'] as String? ?? '',
  );
}

const List<QuickReply> _defaults = [
  QuickReply(id: 'continue', label: 'Continue', text: 'Continue the response.'),
  QuickReply(id: 'tell-more', label: 'Tell more', text: 'Tell me more.'),
  QuickReply(id: 'what-next', label: 'What next?', text: 'What happens next?'),
  QuickReply(id: 'look-around', label: 'Look around', text: '*looks around*'),
];

class QuickRepliesNotifier extends AsyncNotifier<List<QuickReply>> {
  static const _storageKey = 'quick_replies_list_v1';

  @override
  Future<List<QuickReply>> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      return List<QuickReply>.from(_defaults);
    }
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => QuickReply.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return List<QuickReply>.from(_defaults);
    }
  }

  Future<void> _persist(List<QuickReply> items) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(
      _storageKey,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> add(String label, String text) async {
    final current = state.value ?? const [];
    final id = 'qr-${DateTime.now().microsecondsSinceEpoch}';
    final next = [...current, QuickReply(id: id, label: label, text: text)];
    state = AsyncData(next);
    await _persist(next);
  }

  Future<void> edit(String id, {String? label, String? text}) async {
    final current = state.value ?? const [];
    final next = current
        .map((q) => q.id == id ? q.copyWith(label: label, text: text) : q)
        .toList();
    state = AsyncData(next);
    await _persist(next);
  }

  Future<void> remove(String id) async {
    final current = state.value ?? const [];
    final next = current.where((q) => q.id != id).toList();
    state = AsyncData(next);
    await _persist(next);
  }

  Future<void> reorder(int from, int to) async {
    final current = state.value ?? const [];
    if (from < 0 || to < 0 || from >= current.length || to >= current.length) {
      return;
    }
    final next = List<QuickReply>.from(current);
    final item = next.removeAt(from);
    next.insert(to, item);
    state = AsyncData(next);
    await _persist(next);
  }
}

final quickRepliesProvider =
    AsyncNotifierProvider<QuickRepliesNotifier, List<QuickReply>>(
      QuickRepliesNotifier.new,
    );
