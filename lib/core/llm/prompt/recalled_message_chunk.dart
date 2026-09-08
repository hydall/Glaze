class RecalledMessageChunk {
  final String text;
  final List<String> messageIds;

  const RecalledMessageChunk({required this.text, this.messageIds = const []});

  Map<String, dynamic> toJson() => {'text': text, 'messageIds': messageIds};

  factory RecalledMessageChunk.fromJson(Map<String, dynamic> json) =>
      RecalledMessageChunk(
        text: json['text'] as String? ?? '',
        messageIds: (json['messageIds'] as List? ?? const []).cast<String>(),
      );
}
