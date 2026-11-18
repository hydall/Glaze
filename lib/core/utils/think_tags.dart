final _thinkTagRegex = RegExp(r'<think\b[^>]*>[\s\S]*?<\/think\b[^>]*>', caseSensitive: false);
final _thinkTagAltRegex = RegExp(r'<think\b([^>]*?)(?:>|\n)([\s\S]*?)<\/think\b', caseSensitive: false);
final _thinkingTagRegex = RegExp(r'<thinking\b[^>]*>[\s\S]*?<\/thinking\b[^>]*>', caseSensitive: false);
final _thinkingTagAltRegex = RegExp(r'<thinking\b([^>]*?)(?:>|\n)([\s\S]*?)<\/thinking\b', caseSensitive: false);

final _stripThinkCache = <String, String>{};

String stripThinkTags(String text) {
  if (_stripThinkCache.containsKey(text)) return _stripThinkCache[text]!;
  if (text.length < 8 && !text.contains('<think')) return text;
  var result = text.replaceAll(_thinkTagRegex, '');
  result = result.replaceAll(_thinkTagAltRegex, '');
  result = result.replaceAll(_thinkingTagRegex, '');
  result = result.replaceAll(_thinkingTagAltRegex, '');
  result = result.trim();
  if (_stripThinkCache.length > 500) _stripThinkCache.clear();
  _stripThinkCache[text] = result;
  return result;
}