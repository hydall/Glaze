/// A language translation can target: the code is what settings store, the
/// English name is what the translator prompt asks for, the native name is
/// what the picker shows.
class TranslationLanguage {
  final String code;
  final String englishName;
  final String nativeName;

  const TranslationLanguage(this.code, this.englishName, this.nativeName);
}

const List<TranslationLanguage> kTranslationLanguages = [
  TranslationLanguage('en', 'English', 'English'),
  TranslationLanguage('ru', 'Russian', 'Русский'),
  TranslationLanguage('uk', 'Ukrainian', 'Українська'),
  TranslationLanguage('es', 'Spanish', 'Español'),
  TranslationLanguage('pt', 'Portuguese', 'Português'),
  TranslationLanguage('fr', 'French', 'Français'),
  TranslationLanguage('de', 'German', 'Deutsch'),
  TranslationLanguage('it', 'Italian', 'Italiano'),
  TranslationLanguage('pl', 'Polish', 'Polski'),
  TranslationLanguage('tr', 'Turkish', 'Türkçe'),
  TranslationLanguage('ja', 'Japanese', '日本語'),
  TranslationLanguage('ko', 'Korean', '한국어'),
  TranslationLanguage('zh', 'Chinese (Simplified)', '简体中文'),
];

/// The entry for [code], or null for a code this build does not list.
TranslationLanguage? translationLanguageByCode(String code) {
  for (final language in kTranslationLanguages) {
    if (language.code == code) return language;
  }
  return null;
}

/// The language [code] names, falling back to English for an unknown one.
TranslationLanguage resolveTranslationLanguage(String code) =>
    translationLanguageByCode(code) ?? kTranslationLanguages.first;
