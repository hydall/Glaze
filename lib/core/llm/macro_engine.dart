import 'dart:math';

class MacroContext {
  final String charName;
  final String? charDescription;
  final String? charScenario;
  final String? charPersonality;
  final String? charMesExample;
  final String userName;
  final String? personaPrompt;
  final String? reasoningStart;
  final String? reasoningEnd;
  final Map<String, String> sessionVars;
  final Map<String, String> globalVars;
  final String charId;
  final String sessionId;
  final String? summaryContent;
  final String? memoryContent;
  final String? lorebooksContent;
  final String? guidanceText;
  final String? macroName;
  final String? arcContent;
  final String? entitiesContent;

  /// Compiled `<studio_session_state>` block from committed ledger tracker rows.
  /// Injected via `{{studio_state}}` macro. Null/empty when Studio Ledger is
  /// disabled or no state has been written yet.
  final String? studioSessionState;

  const MacroContext({
    required this.charName,
    this.charDescription,
    this.charScenario,
    this.charPersonality,
    this.charMesExample,
    this.userName = 'User',
    this.personaPrompt,
    this.reasoningStart,
    this.reasoningEnd,
    this.sessionVars = const {},
    this.globalVars = const {},
    required this.charId,
    required this.sessionId,
    this.summaryContent,
    this.memoryContent,
    this.lorebooksContent,
    this.guidanceText,
    this.macroName,
    this.arcContent,
    this.entitiesContent,
    this.studioSessionState,
  });

  /// Context for preset-only token accounting: external injections (character,
  /// persona, memory, lorebooks, summary, guidance) are blanked; in-preset
  /// session/global vars and setvar/getvar still resolve.
  MacroContext forPresetAccounting() {
    return MacroContext(
      charName: '',
      charDescription: null,
      charScenario: null,
      charPersonality: null,
      charMesExample: null,
      userName: '',
      personaPrompt: null,
      reasoningStart: reasoningStart,
      reasoningEnd: reasoningEnd,
      sessionVars: sessionVars,
      globalVars: globalVars,
      charId: charId,
      sessionId: sessionId,
      summaryContent: null,
      memoryContent: null,
      lorebooksContent: null,
      guidanceText: null,
      macroName: null,
      studioSessionState: null,
    );
  }

  MacroContext copyWith({
    Map<String, String>? sessionVars,
    Map<String, String>? globalVars,
    String? charScenario,
    String? charPersonality,
    String? charDescription,
    Object? summaryContent = _sentinel,
    Object? memoryContent = _sentinel,
    Object? lorebooksContent = _sentinel,
    Object? guidanceText = _sentinel,
    Object? arcContent = _sentinel,
    Object? entitiesContent = _sentinel,
    Object? studioSessionState = _sentinel,
  }) {
    return MacroContext(
      charName: charName,
      charDescription: charDescription ?? this.charDescription,
      charScenario: charScenario ?? this.charScenario,
      charPersonality: charPersonality ?? this.charPersonality,
      charMesExample: charMesExample,
      userName: userName,
      personaPrompt: personaPrompt,
      reasoningStart: reasoningStart,
      reasoningEnd: reasoningEnd,
      sessionVars: sessionVars ?? this.sessionVars,
      globalVars: globalVars ?? this.globalVars,
      charId: charId,
      sessionId: sessionId,
      summaryContent: identical(summaryContent, _sentinel)
          ? this.summaryContent
          : summaryContent as String?,
      memoryContent: identical(memoryContent, _sentinel)
          ? this.memoryContent
          : memoryContent as String?,
      lorebooksContent: identical(lorebooksContent, _sentinel)
          ? this.lorebooksContent
          : lorebooksContent as String?,
      guidanceText: identical(guidanceText, _sentinel)
          ? this.guidanceText
          : guidanceText as String?,
      macroName: macroName,
      arcContent: identical(arcContent, _sentinel)
          ? this.arcContent
          : arcContent as String?,
      entitiesContent: identical(entitiesContent, _sentinel)
          ? this.entitiesContent
          : entitiesContent as String?,
      studioSessionState: identical(studioSessionState, _sentinel)
          ? this.studioSessionState
          : studioSessionState as String?,
    );
  }

  static const Object _sentinel = Object();

  Map<String, dynamic> toJson() => {
    'charName': charName,
    'charDescription': charDescription,
    'charScenario': charScenario,
    'charPersonality': charPersonality,
    'charMesExample': charMesExample,
    'userName': userName,
    'personaPrompt': personaPrompt,
    'reasoningStart': reasoningStart,
    'reasoningEnd': reasoningEnd,
    'sessionVars': sessionVars,
    'globalVars': globalVars,
    'charId': charId,
    'sessionId': sessionId,
    'summaryContent': summaryContent,
    'memoryContent': memoryContent,
    'lorebooksContent': lorebooksContent,
    'guidanceText': guidanceText,
    'macroName': macroName,
    'arcContent': arcContent,
    'entitiesContent': entitiesContent,
    'studioSessionState': studioSessionState,
  };

  factory MacroContext.fromJson(Map<String, dynamic> json) => MacroContext(
    charName: json['charName'] as String,
    charDescription: json['charDescription'] as String?,
    charScenario: json['charScenario'] as String?,
    charPersonality: json['charPersonality'] as String?,
    charMesExample: json['charMesExample'] as String?,
    userName: json['userName'] as String? ?? 'User',
    personaPrompt: json['personaPrompt'] as String?,
    reasoningStart: json['reasoningStart'] as String?,
    reasoningEnd: json['reasoningEnd'] as String?,
    sessionVars: Map<String, String>.from(json['sessionVars'] as Map? ?? {}),
    globalVars: Map<String, String>.from(json['globalVars'] as Map? ?? {}),
    charId: json['charId'] as String,
    sessionId: json['sessionId'] as String,
    summaryContent: json['summaryContent'] as String?,
    memoryContent: json['memoryContent'] as String?,
    lorebooksContent: json['lorebooksContent'] as String?,
    guidanceText: json['guidanceText'] as String?,
    macroName: json['macroName'] as String?,
    arcContent: json['arcContent'] as String?,
    entitiesContent: json['entitiesContent'] as String?,
    studioSessionState: json['studioSessionState'] as String?,
  );
}

class MacroResult {
  final String text;
  final Map<String, String> sessionVars;
  final Map<String, String> globalVars;
  final bool varsChanged;

  const MacroResult({
    required this.text,
    required this.sessionVars,
    required this.globalVars,
    required this.varsChanged,
  });
}

MacroResult replaceMacros(String text, MacroContext ctx) {
  var result = text;
  final sessionVars = Map<String, String>.from(ctx.sessionVars);
  var pickCount = 0;
  final globalVars = Map<String, String>.from(ctx.globalVars);
  var varsChanged = false;
  final random = Random();

  result = result.replaceAllMapped(
    RegExp(r'\{\{\s*\/\/\s*\}\}[\s\S]*?\{\{\s*\/\/\/\s*\}\}'),
    (_) => '',
  );

  result = result.replaceAllMapped(RegExp(r'\{\{\/\/[^}]*\}\}'), (_) => '');

  final resolvedCharName = ctx.macroName ?? ctx.charName;

  result = result.replaceAllMapped(
    RegExp(r'\{\{char\}\}', caseSensitive: false),
    (_) => resolvedCharName,
  );

  result = result.replaceAllMapped(
    RegExp(r'\{char\}', caseSensitive: false),
    (_) => resolvedCharName,
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{description\}\}', caseSensitive: false),
    (_) => ctx.charDescription ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{description\}', caseSensitive: false),
    (_) => ctx.charDescription ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{scenario\}\}', caseSensitive: false),
    (_) => ctx.charScenario ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{scenario\}', caseSensitive: false),
    (_) => ctx.charScenario ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{personality\}\}', caseSensitive: false),
    (_) => ctx.charPersonality ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{personality\}', caseSensitive: false),
    (_) => ctx.charPersonality ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{mesExamples\}\}', caseSensitive: false),
    (_) => ctx.charMesExample ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{mesExamples\}', caseSensitive: false),
    (_) => ctx.charMesExample ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{user\}\}', caseSensitive: false),
    (_) => ctx.userName,
  );

  result = result.replaceAllMapped(
    RegExp(r'\{user\}', caseSensitive: false),
    (_) => ctx.userName,
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{persona\}\}', caseSensitive: false),
    (_) => ctx.personaPrompt ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{persona\}', caseSensitive: false),
    (_) => ctx.personaPrompt ?? '',
  );

  if (result.contains('{{trim}}')) {
    result = result.replaceAllMapped(
      RegExp(r'\{\{trim\}\}', caseSensitive: false),
      (_) => '',
    );
    result = result.trim();
  }

  result = result.replaceAllMapped(
    RegExp(r'\{\{reasoningPrefix\}\}', caseSensitive: false),
    (_) =>
        ctx.reasoningStart ??
        '<think'
            '>',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{reasoningSuffix\}\}', caseSensitive: false),
    (_) =>
        ctx.reasoningEnd ??
        '</think'
            '>',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{summary\}\}', caseSensitive: false),
    (_) => ctx.summaryContent ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{memory\}\}', caseSensitive: false),
    (_) => ctx.memoryContent ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{arc\}\}', caseSensitive: false),
    (_) => ctx.arcContent ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{studio_state\}\}', caseSensitive: false),
    (_) => ctx.studioSessionState ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{entit(?:y|ies)\}\}', caseSensitive: false),
    (_) => ctx.entitiesContent ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{lorebooks\}\}', caseSensitive: false),
    (_) => ctx.lorebooksContent ?? '',
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{guidance\}\}', caseSensitive: false),
    (_) => ctx.guidanceText ?? '',
  );

  result = _replaceSetVar(
    result,
    'setvar',
    sessionVars,
    () => varsChanged = true,
  );
  result = _replaceSetVar(
    result,
    'setglobalvar',
    globalVars,
    () => varsChanged = true,
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{getvar::([\s\S]*?)\}\}', caseSensitive: false),
    (m) {
      final name = m.group(1)!.trim();
      return sessionVars[name] ?? '';
    },
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{getglobalvar::([\s\S]*?)\}\}', caseSensitive: false),
    (m) {
      final name = m.group(1)!.trim();
      return globalVars[name] ?? '';
    },
  );

  result = result.replaceAllMapped(
    RegExp(
      r'\{\{(lumiaDef|lumiaOOC|lumiaOOCErotic|lumiaOOCEroticBleed|lumiaPersonality|loomRetrofits|loomStyle|loomSummary|loomUtils|sim_tracker|suggest)\}\}',
      caseSensitive: false,
    ),
    (m) {
      final name = m.group(1)!;
      final val = globalVars[name];
      return val ?? m.group(0)!;
    },
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{random::(.*?)\}\}', caseSensitive: false),
    (m) {
      final parts = m.group(1)!.split('::');
      if (parts.isEmpty) return '';
      return parts[random.nextInt(parts.length)];
    },
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{pick::(.*?)\}\}', caseSensitive: false),
    (m) {
      final parts = m.group(1)!.split('::');
      if (parts.isEmpty) return '';
      final version = int.tryParse(sessionVars['__pick_version'] ?? '0') ?? 0;
      final seed =
          '${ctx.charId}_${ctx.sessionId}_pick_${pickCount++}_v$version';
      final hash = _simpleHash(seed);
      return parts[hash % parts.length];
    },
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{roll::(.*?)\}\}', caseSensitive: false),
    (m) {
      final result = _rollDice(m.group(1)!);
      return result != null ? result.toString() : m.group(1)!;
    },
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{date\}\}', caseSensitive: false),
    (_) => DateTime.now().toLocal().toString().split(' ').first,
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{time\}\}', caseSensitive: false),
    (_) => DateTime.now().toLocal().toString().split(' ').last.split('.').first,
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{weekday\}\}', caseSensitive: false),
    (_) {
      final days = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      return days[DateTime.now().weekday - 1];
    },
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{isotime\}\}', caseSensitive: false),
    (_) {
      final now = DateTime.now();
      return '${_pad2(now.hour)}:${_pad2(now.minute)}';
    },
  );

  result = result.replaceAllMapped(
    RegExp(r'\{\{isodate\}\}', caseSensitive: false),
    (_) {
      final now = DateTime.now();
      return '${now.year.toString().padLeft(4, '0')}-${_pad2(now.month)}-${_pad2(now.day)}';
    },
  );

  // {{time::UTC±offset}} — current time shifted to the given UTC offset (in
  // hours, optionally fractional, e.g. {{time::UTC+2}} / {{time::UTC-5.5}}).
  result = result.replaceAllMapped(
    RegExp(r'\{\{time::UTC([+-]?\d+(?:\.\d+)?)\}\}', caseSensitive: false),
    (m) {
      final offsetHours = double.tryParse(m.group(1)!) ?? 0;
      final shifted = DateTime.now().toUtc().add(
        Duration(milliseconds: (offsetHours * 3600 * 1000).round()),
      );
      return '${_pad2(shifted.hour)}:${_pad2(shifted.minute)}:${_pad2(shifted.second)}';
    },
  );

  // {{datetimeformat::FORMAT}} — custom date/time using moment.js-style tokens
  // (e.g. {{datetimeformat::YYYY-MM-DD HH:mm:ss}}).
  result = result.replaceAllMapped(
    RegExp(r'\{\{datetimeformat::([\s\S]*?)\}\}', caseSensitive: false),
    (m) => _formatDateTime(DateTime.now(), m.group(1)!),
  );

  result = result.replaceAll('\\{', '{').replaceAll('\\}', '}');

  return MacroResult(
    text: result,
    sessionVars: sessionVars,
    globalVars: globalVars,
    varsChanged: varsChanged,
  );
}

/// Result of a variable-only macro expansion pass.
class VariableMacroResult {
  final String text;
  final Map<String, String> sessionVars;
  final Map<String, String> globalVars;

  const VariableMacroResult({
    required this.text,
    required this.sessionVars,
    required this.globalVars,
  });
}

/// Expands ONLY `{{setvar}}`, `{{setglobalvar}}`, `{{getvar}}`,
/// `{{getglobalvar}}`, and `{{trim}}` macros, leaving all other `{{...}}`
/// tags untouched for later chat-time expansion.
///
/// This is used at Studio build time to resolve the setvar→getvar variable
/// pipeline (which is order-dependent and cross-block) so that rule values
/// reach their destination blocks even when the CoT dispatcher block is
/// dropped. Other macros (`{{char}}`, `{{user}}`, `{{random::}}`, etc.) are
/// turn-specific or context-specific and must remain as literals until chat
/// time.
///
/// [sessionVars] / [globalVars] are the accumulated variable store from
/// previously-processed blocks (forward accumulation, matching
/// `prompt_builder.dart` block-order semantics). The returned maps include
/// any new variables set by this block.
VariableMacroResult expandVariableMacros(
  String text, {
  Map<String, String> sessionVars = const {},
  Map<String, String> globalVars = const {},
}) {
  var result = text;
  final sVars = Map<String, String>.from(sessionVars);
  final gVars = Map<String, String>.from(globalVars);

  result = _replaceSetVar(result, 'setvar', sVars, () {});
  result = _replaceSetVar(result, 'setglobalvar', gVars, () {});

  result = result.replaceAllMapped(
    RegExp(r'\{\{getvar::([\s\S]*?)\}\}', caseSensitive: false),
    (m) => sVars[m.group(1)!.trim()] ?? '',
  );
  result = result.replaceAllMapped(
    RegExp(r'\{\{getglobalvar::([\s\S]*?)\}\}', caseSensitive: false),
    (m) => gVars[m.group(1)!.trim()] ?? '',
  );

  if (result.contains('{{trim}}')) {
    result = result.replaceAllMapped(
      RegExp(r'\{\{trim\}\}', caseSensitive: false),
      (_) => '',
    );
    result = result.trim();
  }

  return VariableMacroResult(
    text: result,
    sessionVars: sVars,
    globalVars: gVars,
  );
}

String _pad2(int n) => n.toString().padLeft(2, '0');

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const _monthNamesShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _weekdayNamesShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Formats [dt] using a subset of moment.js tokens (YYYY/YY, MMMM/MMM/MM/M,
/// DD/D, dddd/ddd, HH/H, hh/h, mm/m, ss/s, A/a). Unknown text is passed
/// through unchanged. Used by the `{{datetimeformat::…}}` macro.
String _formatDateTime(DateTime dt, String pattern) {
  final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final tokens = RegExp(
    r'YYYY|YY|MMMM|MMM|MM|M|DD|D|dddd|ddd|HH|H|hh|h|mm|m|ss|s|A|a',
  );
  return pattern.replaceAllMapped(tokens, (m) {
    switch (m.group(0)) {
      case 'YYYY':
        return dt.year.toString().padLeft(4, '0');
      case 'YY':
        return (dt.year % 100).toString().padLeft(2, '0');
      case 'MMMM':
        return _monthNames[dt.month - 1];
      case 'MMM':
        return _monthNamesShort[dt.month - 1];
      case 'MM':
        return _pad2(dt.month);
      case 'M':
        return dt.month.toString();
      case 'DD':
        return _pad2(dt.day);
      case 'D':
        return dt.day.toString();
      case 'dddd':
        return _weekdayNames[dt.weekday - 1];
      case 'ddd':
        return _weekdayNamesShort[dt.weekday - 1];
      case 'HH':
        return _pad2(dt.hour);
      case 'H':
        return dt.hour.toString();
      case 'hh':
        return _pad2(h12);
      case 'h':
        return h12.toString();
      case 'mm':
        return _pad2(dt.minute);
      case 'm':
        return dt.minute.toString();
      case 'ss':
        return _pad2(dt.second);
      case 's':
        return dt.second.toString();
      case 'A':
        return dt.hour < 12 ? 'AM' : 'PM';
      case 'a':
        return dt.hour < 12 ? 'am' : 'pm';
      default:
        return m.group(0)!;
    }
  });
}

int _simpleHash(String input) {
  var hash = 0;
  for (var i = 0; i < input.length; i++) {
    hash = ((hash << 5) - hash + input.codeUnitAt(i));
    hash = (hash | 0).toSigned(32);
  }
  return hash.abs();
}

int? _rollDice(String spec) {
  final match = RegExp(r'(\d+)d(\d+)', caseSensitive: false).firstMatch(spec);
  if (match == null) return null;
  final count = int.parse(match.group(1)!);
  final sides = int.parse(match.group(2)!);
  final random = Random();
  var total = 0;
  for (var i = 0; i < count; i++) {
    total += random.nextInt(sides) + 1;
  }
  return total;
}

/// Extracts payload values from `{{setvar::name::value}}` / `{{setglobalvar::…}}`
/// without mutating [vars]. Used for preset token accounting.
List<String> extractSetvarPayloads(String text, String keyword) {
  final tag = '{{$keyword::';
  final values = <String>[];
  var i = 0;
  while (i < text.length) {
    final idx = text.indexOf(tag, i);
    if (idx < 0) break;
    final afterTag = idx + tag.length;
    final secondDblColon = text.indexOf('::', afterTag);
    if (secondDblColon < 0) break;
    final valueStart = secondDblColon + 2;
    var depth = 1;
    var pos = valueStart;
    while (pos < text.length && depth > 0) {
      if (pos + 1 < text.length && text[pos] == '{' && text[pos + 1] == '{') {
        depth++;
        pos += 2;
      } else if (pos + 1 < text.length &&
          text[pos] == '}' &&
          text[pos + 1] == '}') {
        depth--;
        if (depth == 0) break;
        pos += 2;
      } else {
        pos++;
      }
    }
    if (depth != 0) break;
    final value = text.substring(valueStart, pos).trim();
    if (value.isNotEmpty) values.add(value);
    i = pos + 2;
  }
  return values;
}

String _replaceSetVar(
  String text,
  String keyword,
  Map<String, String> vars,
  void Function() markChanged,
) {
  final tag = '{{$keyword::';
  final buf = StringBuffer();
  int i = 0;
  while (i < text.length) {
    final idx = text.indexOf(tag, i);
    if (idx < 0) {
      buf.write(text.substring(i));
      break;
    }
    buf.write(text.substring(i, idx));
    final afterTag = idx + tag.length;
    final secondDblColon = text.indexOf('::', afterTag);
    if (secondDblColon < 0) {
      buf.write(text.substring(idx));
      break;
    }
    final name = text.substring(afterTag, secondDblColon).trim();
    final valueStart = secondDblColon + 2;
    var depth = 1;
    var pos = valueStart;
    while (pos < text.length && depth > 0) {
      if (pos + 1 < text.length && text[pos] == '{' && text[pos + 1] == '{') {
        depth++;
        pos += 2;
      } else if (pos + 1 < text.length &&
          text[pos] == '}' &&
          text[pos + 1] == '}') {
        depth--;
        if (depth == 0) break;
        pos += 2;
      } else {
        pos++;
      }
    }
    if (depth != 0) {
      buf.write(text.substring(idx));
      break;
    }
    final value = text.substring(valueStart, pos).trim();
    vars[name] = value;
    markChanged();
    i = pos + 2;
  }
  return buf.toString();
}
