/// The text side of the 3D visual-novel mode: the bundled assets, the page the
/// engine runs in, and how a model's reply becomes a script.
///
/// Everything here is pure so it can be tested without a WebView or a model.
library;

const String kVnPageAsset = 'assets/vn3d/index.html';
const String kVnThreeAsset = 'assets/vn3d/three.min.js';
const String kVnEngineAsset = 'assets/vn3d/engine.js';
const String kVnSampleAsset = 'assets/vn3d/sample_game.txt';
const String kVnModelSpecAsset = 'assets/vn3d/model_spec.txt';

const String _threeSlot = '<!--VN3D_THREE-->';
const String _engineSlot = '<!--VN3D_ENGINE-->';

/// The engine page with three.js and the engine inlined.
///
/// The page is handed to the WebView as data rather than as a file URL, so it
/// loads the same way on every platform and needs no asset server.
String buildVnPage({
  required String shell,
  required String three,
  required String engine,
}) {
  if (!shell.contains(_threeSlot) || !shell.contains(_engineSlot)) {
    throw const FormatException('VN page shell is missing a script slot');
  }
  return shell
      .replaceFirst(_threeSlot, '<script>${_inlineScript(three)}</script>')
      .replaceFirst(_engineSlot, '<script>${_inlineScript(engine)}</script>');
}

/// [source] safe to place between `<script>` tags: a literal `</script` would
/// close the element early.
String _inlineScript(String source) =>
    source.replaceAll(RegExp('</script', caseSensitive: false), r'<\/script');

final RegExp _thinkBlock = RegExp(
  r'<think(?:ing)?>[\s\S]*?</think(?:ing)?>',
  caseSensitive: false,
);
final RegExp _fence = RegExp(r'```[^\n]*\n([\s\S]*?)(?:```|$)');
final RegExp _sceneLine = RegExp(r'^\s*#\s*\S', multiLine: true);

/// The game script inside a model reply, or null when the reply holds none.
///
/// Models tend to wrap the script in a code fence or think out loud first, so
/// reasoning is dropped and the first fenced block wins when there is one. A
/// reply counts as a script only if it has at least one `# scene` line.
String? extractVnScript(String reply) {
  var text = reply.replaceAll(_thinkBlock, '');
  final fenced = _fence.firstMatch(text);
  if (fenced != null) text = fenced.group(1)!;
  text = text.trim();
  if (!_sceneLine.hasMatch(text)) return null;
  return text;
}

/// The messages that ask the active model for a whole game.
///
/// [spec] is the engine's language description; [language] is the name of
/// the language the player reads, e.g. "Russian".
List<Map<String, String>> buildVnGenerationMessages({
  required String spec,
  required String premise,
  required String language,
}) {
  final idea = premise.trim().isEmpty
      ? 'a short mystery in a small school'
      : premise.trim();
  return [
    {'role': 'system', 'content': spec.trim()},
    {
      'role': 'user',
      'content':
          'Write a game of 2 to 4 scenes about: $idea\n'
          'All names, lines and narration in $language. '
          'Commands, types and colors stay as in the spec.',
    },
  ];
}
