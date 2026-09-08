class RuntimePromptBlock {
  final String id;
  final String content;
  final int depth;
  final String role;

  const RuntimePromptBlock({
    required this.id,
    required this.content,
    required this.depth,
    required this.role,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'depth': depth,
    'role': role,
  };

  factory RuntimePromptBlock.fromJson(Map<String, dynamic> json) =>
      RuntimePromptBlock(
        id: json['id'] as String,
        content: json['content'] as String,
        depth: json['depth'] as int? ?? 0,
        role: json['role'] as String? ?? 'system',
      );
}
