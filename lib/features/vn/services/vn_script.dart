/// The text side of the 3D visual-novel mode: the bundled assets, the page the
/// engine runs in, and how a model's reply is cleaned up.
///
/// Everything here is pure so it can be tested without a WebView or a model.
library;

const String kVnPageAsset = 'assets/vn3d/index.html';
const String kVnThreeAsset = 'assets/vn3d/three.min.js';
const String kVnEngineAsset = 'assets/vn3d/engine.js';
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

/// A model reply without its reasoning and its code fence.
///
/// Models tend to wrap the answer in a fence or think out loud first, so
/// reasoning is dropped and the first fenced block wins when there is one.
String cleanVnReply(String reply) {
  var text = reply.replaceAll(_thinkBlock, '');
  final fenced = _fence.firstMatch(text);
  if (fenced != null) text = fenced.group(1)!;
  return text.trim();
}
