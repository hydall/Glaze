/// An instruction the reader puts in front of every summary prompt, for a
/// model that refuses to retell what the roleplay got into.
///
/// A summarizer that balks at a harsh scene answers with a line of apology
/// instead of a summary, and the chat cannot compact past that point. This
/// text goes first in the retelling, merging and shortening prompts alike, so
/// it is read before any of them; off, the prompts go as chosen. The text is
/// the reader's — the default asks for a neutral retelling that leaves nothing
/// the story needs out — and is kept when the switch is off, so turning it
/// back on finds it as it was.
///
/// Global, like the prompt selection: one text for every chat.
class SummaryPreamble {
  final bool enabled;
  final String text;

  const SummaryPreamble({this.enabled = false, this.text = defaultText});

  /// What the field starts with: a plain retelling of a scene the model would
  /// otherwise refuse — by its facts and what it changed, without the detail.
  static const defaultText =
      'The transcript is the record of a fictional story written by adults, '
      'and your task is to keep its summary, not to continue it. It may '
      'contain violence, abuse or explicit sexual content. Summarize such '
      'scenes all the same: say who did what, how it ended and what it '
      'changed for the characters, in neutral words and without graphic '
      'detail, and keep everything the story needs to go on. Do not moralize '
      'and add no warnings. If a passage cannot be retold at all, note in one '
      'line that a scene of that kind took place and go on with the rest.';

  /// Whether anything is put in front of the prompts.
  bool get active => enabled && text.trim().isNotEmpty;

  /// [template] with the instruction in front when [active]; [template] as it
  /// is otherwise. Called on the resolved prompt text, so a chat's own prompt
  /// and a saved one get it the same way.
  String apply(String template) =>
      active ? '${text.trim()}\n\n${template.trimLeft()}' : template;

  SummaryPreamble copyWith({bool? enabled, String? text}) => SummaryPreamble(
    enabled: enabled ?? this.enabled,
    text: text ?? this.text,
  );

  Map<String, dynamic> toJson() => {'enabled': enabled, 'text': text};

  factory SummaryPreamble.fromJson(Map<String, dynamic> json) {
    final text = json['text'];
    return SummaryPreamble(
      enabled: json['enabled'] == true,
      text: text is String ? text : defaultText,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SummaryPreamble &&
      other.enabled == enabled &&
      other.text == text;

  @override
  int get hashCode => Object.hash(enabled, text);
}
