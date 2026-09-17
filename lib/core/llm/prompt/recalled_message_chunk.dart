class RecalledMessageChunk {
  final String text;
  final List<String> messageIds;
  final String? ledgerRange;

  const RecalledMessageChunk({
    required this.text,
    this.messageIds = const [],
    this.ledgerRange,
  });

  Map<String, dynamic> toJson() => {
    'text': text,
    'messageIds': messageIds,
    if (ledgerRange != null) 'ledgerRange': ledgerRange,
  };

  factory RecalledMessageChunk.fromJson(Map<String, dynamic> json) =>
      RecalledMessageChunk(
        text: json['text'] as String? ?? '',
        messageIds: (json['messageIds'] as List? ?? const []).cast<String>(),
        ledgerRange: json['ledgerRange'] as String?,
      );
}
