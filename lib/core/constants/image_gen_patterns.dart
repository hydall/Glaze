class ImgGenPatterns {
  ImgGenPatterns._();

  static final imgGenRegex = RegExp(r'\[IMG:GEN(?::(.*?))?\]');
  static final imgResultRegex = RegExp(r'\[IMG:RESULT:(.*?)\]');
  static final imgErrorRegex = RegExp(r'\[IMG:ERROR:(.*?)\]');

  static final imgResultStripRegex = RegExp(r'\[IMG:RESULT:[^\]]*\]');
  static final imgErrorStripRegex = RegExp(r'\[IMG:ERROR:[^\]]*\]');
  static final imgGenStripRegex = RegExp(r'\[IMG:GEN[^\]]*\]');

  static final htmlIigTagRegex = RegExp(
    r"<img\s[^>]*?data-iig-instruction\s*=\s*'([^']*)'[^>]*>",
    caseSensitive: false,
    dotAll: true,
  );
  static final htmlIigTagDoubleRegex = RegExp(
    r'''<img\s[^>]*?data-iig-instruction\s*=\s*"([^"]*)"[^>]*>''',
    caseSensitive: false,
    dotAll: true,
  );
  static final htmlIigAnyAttrRegex = RegExp(
    r'<img\s[^>]*?data-iig-instruction\s*=[^>]*>',
    caseSensitive: false,
    dotAll: true,
  );
  static final imgSrcGenRegex = RegExp(
    r'''<img\b[^>]*?\bsrc\s*=\s*["']\[IMG:GEN[^\]]*\]["'][^>]*>''',
    caseSensitive: false,
    dotAll: true,
  );
  static final imgGenHtmlRegex = RegExp(
    r"""<img\s[^>]*?data-iig-instruction\s*=\s*'([^']*)'[^>]*?src="\[IMG:GEN\]"[^>]*>""",
    caseSensitive: false,
    dotAll: true,
  );

  static final base64DataUrlRegex = RegExp(
    r'data:image/[^;]+;base64,[A-Za-z0-9+/=]{256,}',
  );
  static final imgTagDataSrcRegex = RegExp(
    r'<img\s[^>]*?src="data:image/[^"]{256,}?"[^>]*\/?>',
  );

  static const imgGenPattern = r'\[IMG:RESULT:(.*?)\]';

  static bool hasAnyImageTag(String text) {
    return imgGenRegex.hasMatch(text) ||
        imgResultRegex.hasMatch(text) ||
        imgErrorRegex.hasMatch(text) ||
        htmlIigTagRegex.hasMatch(text) ||
        htmlIigTagDoubleRegex.hasMatch(text);
  }

  static String stripHtmlImgTags(String text) {
    return text.replaceAll(htmlIigAnyAttrRegex, '');
  }
}
