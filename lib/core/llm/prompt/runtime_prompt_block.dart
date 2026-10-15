/// Where a [RuntimePromptBlock] goes in the assembled request.
enum RuntimePromptPlacement {
  /// Into the chat history, [RuntimePromptBlock.depth] messages from the end.
  depth,

  /// Straight after the preset's main prompt.
  afterMain,

  /// Straight before the preset's main prompt.
  beforeMain,
}

class RuntimePromptBlock {
  final String id;
  final String content;
  final int depth;
  final String role;
  final RuntimePromptPlacement placement;

  const RuntimePromptBlock({
    required this.id,
    required this.content,
    required this.depth,
    required this.role,
    this.placement = RuntimePromptPlacement.depth,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'depth': depth,
    'role': role,
    'placement': placement.name,
  };

  factory RuntimePromptBlock.fromJson(Map<String, dynamic> json) =>
      RuntimePromptBlock(
        id: json['id'] as String,
        content: json['content'] as String,
        depth: json['depth'] as int? ?? 0,
        role: json['role'] as String? ?? 'system',
        placement: RuntimePromptPlacement.values.firstWhere(
          (p) => p.name == json['placement'],
          orElse: () => RuntimePromptPlacement.depth,
        ),
      );
}
