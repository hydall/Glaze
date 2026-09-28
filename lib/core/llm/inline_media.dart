/// Base64 media embedded in prompt *text* — a card's greeting with an
/// `<img src="data:image/png;base64,…">`, a pasted data URI, an imported chat
/// that inlined its pictures.
///
/// Such a payload reaches the model as plain characters: it cannot see the
/// picture, but it pays for every byte — a single photo is hundreds of
/// thousands of tokens, enough to push a request past a 1M-token provider
/// limit on its own. Attachments are unaffected: they travel as separate
/// image parts, never inside the text.
///
/// [stripInlineMedia] is applied both where the prompt is sent and where it
/// is counted, so the context budget and the request always agree.
String stripInlineMedia(String text) {
  if (text.length < _minPayload || !text.contains(';base64,')) return text;
  return text
      .replaceAllMapped(_imgTag, (m) => _placeholder(m[1]!))
      .replaceAllMapped(_dataUri, (m) => _placeholder(m[1]!));
}

/// Shorter payloads (icons, tracking pixels) are cheap and left alone.
const _minPayload = 256;

final _imgTag = RegExp(
  r'''<img\b[^>]*?\bsrc\s*=\s*["']data:([a-z]+)/[^;"']+;base64,'''
  r'''[A-Za-z0-9+/=\s]{256,}["'][^>]*>''',
  caseSensitive: false,
);

final _dataUri = RegExp(
  r'data:([a-z]+)/[a-z0-9.+-]+;base64,[A-Za-z0-9+/=]{256,}',
  caseSensitive: false,
);

String _placeholder(String kind) => switch (kind.toLowerCase()) {
  'image' => '[image]',
  'audio' => '[audio]',
  'video' => '[video]',
  _ => '[file]',
};
