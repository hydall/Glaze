/// SillyTavern's variable and conditional macros, evaluated left to right the
/// way its macro engine does:
///
/// * `{{setvar::name::value}}`, `{{setglobalvar::…}}` and the scoped form
///   `{{setvar::name}}value{{/setvar}}`; the value's own macros are resolved
///   when it is set, so a later `{{getvar::name}}` returns finished text;
/// * `{{getvar::name}}`, `{{getglobalvar::name}}`;
/// * `{{if condition}}…{{else}}…{{/if}}`, with `!` for negation. Only the
///   chosen branch is evaluated, so a `{{setvar}}` in the other one never runs.
///
/// `setchatvar` / `getchatvar` are aliases of `setvar` / `getvar` (session
/// variables are the chat's). Every other `{{…}}` is left as it is, with the
/// variable macros nested inside it resolved.
class VariableMacroEvaluator {
  final Map<String, String> sessionVars;
  final Map<String, String> globalVars;

  /// Values a bare `{{if name}}` condition resolves to (`description`,
  /// `persona`, …). A name missing here is a literal, hence truthy.
  final Map<String, String> conditionMacros;
  final void Function() onVarsChanged;

  /// Leaves an `{{if}}` block as it is when its condition still holds a macro
  /// this pass does not resolve (`{{user}}` at Studio build time), so it is
  /// decided later rather than on a placeholder.
  final bool deferUnresolvedConditions;

  VariableMacroEvaluator({
    required this.sessionVars,
    required this.globalVars,
    this.conditionMacros = const {},
    required this.onVarsChanged,
    this.deferUnresolvedConditions = false,
  });

  String evaluate(String text) {
    if (!text.contains('{{')) return text;
    final out = StringBuffer();
    var i = 0;
    while (i < text.length) {
      final open = text.indexOf('{{', i);
      if (open < 0) {
        out.write(text.substring(i));
        break;
      }
      out.write(text.substring(i, open));
      final end = _macroEnd(text, open);
      if (end < 0) {
        out.write(text.substring(open));
        break;
      }
      final body = text.substring(open + 2, end - 2);
      final parts = _splitArgs(body);
      final name = parts.first.trim().toLowerCase();

      if (_isIf(body)) {
        final block = _findIfBlock(text, end);
        if (block != null) {
          final taken = _ifTaken(body);
          out.write(
            taken == null
                ? text.substring(open, block.end)
                : evaluate(taken ? block.then : block.otherwise),
          );
          i = block.end;
          continue;
        }
      } else if (_setters.containsKey(name)) {
        final vars = _setters[name] == _Scope.global ? globalVars : sessionVars;
        if (parts.length >= 3) {
          _set(vars, parts[1], body.substring(_valueStart(body)));
          i = end;
          continue;
        }
        if (parts.length == 2) {
          final scoped = _findScopedEnd(text, end, name);
          if (scoped != null) {
            _set(vars, parts[1], text.substring(end, scoped.contentEnd));
            i = scoped.end;
            continue;
          }
        }
      } else if (_getters.containsKey(name) && parts.length >= 2) {
        final vars = _getters[name] == _Scope.global ? globalVars : sessionVars;
        out.write(vars[evaluate(parts.sublist(1).join('::')).trim()] ?? '');
        i = end;
        continue;
      }

      out.write('{{${evaluate(body)}}}');
      i = end;
    }
    return out.toString();
  }

  void _set(Map<String, String> vars, String rawName, String rawValue) {
    vars[evaluate(rawName).trim()] = evaluate(rawValue).trim();
    onVarsChanged();
  }

  /// Whether the `{{if}}` branch is taken; null when the decision is deferred.
  bool? _ifTaken(String body) {
    var condition = body.trimLeft().substring(2);
    if (condition.startsWith('::')) condition = condition.substring(2);
    condition = condition.trim();
    var negate = false;
    if (condition.startsWith('!')) {
      negate = true;
      condition = condition.substring(1).trim();
    }
    final bare = RegExp(r'^[A-Za-z_]\w*$').hasMatch(condition);
    final value = bare && conditionMacros.containsKey(condition)
        ? conditionMacros[condition]!
        : evaluate(condition);
    if (deferUnresolvedConditions && value.contains('{{')) return null;
    return _truthy(value) != negate;
  }
}

enum _Scope { session, global }

const _setters = {
  'setvar': _Scope.session,
  'setchatvar': _Scope.session,
  'setglobalvar': _Scope.global,
};

const _getters = {
  'getvar': _Scope.session,
  'getchatvar': _Scope.session,
  'getglobalvar': _Scope.global,
};

bool _truthy(String value) {
  final v = value.trim().toLowerCase();
  return v.isNotEmpty && v != 'false' && v != '0';
}

bool _isIf(String body) => RegExp(r'^\s*if(?:\s|::)').hasMatch(body);

/// Index just past the `}}` closing the macro that opens at [open], counting
/// nested `{{…}}`; -1 when it never closes.
int _macroEnd(String text, int open) {
  var depth = 0;
  var i = open;
  while (i + 1 < text.length) {
    if (text[i] == '{' && text[i + 1] == '{') {
      depth++;
      i += 2;
    } else if (text[i] == '}' && text[i + 1] == '}') {
      depth--;
      i += 2;
      if (depth == 0) return i;
    } else {
      i++;
    }
  }
  return -1;
}

/// [body] split on its top-level `::` (a nested macro's own `::` stays put).
List<String> _splitArgs(String body) {
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  var i = 0;
  while (i < body.length) {
    if (body.startsWith('{{', i)) {
      depth++;
      i += 2;
    } else if (body.startsWith('}}', i)) {
      depth--;
      i += 2;
    } else if (depth == 0 && body.startsWith('::', i)) {
      parts.add(body.substring(start, i));
      i += 2;
      start = i;
    } else {
      i++;
    }
  }
  parts.add(body.substring(start));
  return parts;
}

/// Where the value of `setvar::name::value` starts in [body].
int _valueStart(String body) {
  final first = _splitArgs(body);
  return first[0].length + 2 + first[1].length + 2;
}

/// The next macro after [from]: its body, start and end; null when none.
({String body, int start, int end})? _nextMacro(String text, int from) {
  final open = text.indexOf('{{', from);
  if (open < 0) return null;
  final end = _macroEnd(text, open);
  if (end < 0) return null;
  return (body: text.substring(open + 2, end - 2), start: open, end: end);
}

/// The branches of the `{{if}}` whose opening tag ends at [from].
({String then, String otherwise, int end})? _findIfBlock(
  String text,
  int from,
) {
  var depth = 1;
  int? elseStart;
  int? elseEnd;
  var pos = from;
  while (true) {
    final macro = _nextMacro(text, pos);
    if (macro == null) return null;
    final tag = macro.body.trim().toLowerCase();
    if (_isIf(macro.body)) {
      depth++;
    } else if (tag == '/if') {
      depth--;
      if (depth == 0) {
        return (
          then: text.substring(from, elseStart ?? macro.start),
          otherwise: elseEnd == null
              ? ''
              : text.substring(elseEnd, macro.start),
          end: macro.end,
        );
      }
    } else if (tag == 'else' && depth == 1 && elseStart == null) {
      elseStart = macro.start;
      elseEnd = macro.end;
    }
    pos = macro.end;
  }
}

/// The closing `{{/name}}` of a scoped `{{name::var}}` whose tag ends at
/// [from], counting scoped openers of the same macro in between.
({int contentEnd, int end})? _findScopedEnd(
  String text,
  int from,
  String name,
) {
  var depth = 1;
  var pos = from;
  while (true) {
    final macro = _nextMacro(text, pos);
    if (macro == null) return null;
    final parts = _splitArgs(macro.body);
    final tag = parts.first.trim().toLowerCase();
    if (tag == name && parts.length == 2) {
      depth++;
    } else if (tag == '/$name') {
      depth--;
      if (depth == 0) return (contentEnd: macro.start, end: macro.end);
    }
    pos = macro.end;
  }
}

/// Raw payloads of every `{{keyword::name::value}}` and scoped
/// `{{keyword::name}}value{{/keyword}}` in [text], without evaluating
/// anything. Used for preset token accounting.
List<String> extractSetvarPayloads(String text, String keyword) {
  final values = <String>[];
  var pos = 0;
  while (true) {
    final macro = _nextMacro(text, pos);
    if (macro == null) break;
    final parts = _splitArgs(macro.body);
    pos = macro.end;
    if (parts.first.trim().toLowerCase() != keyword) continue;
    String? value;
    if (parts.length >= 3) {
      value = macro.body.substring(_valueStart(macro.body));
    } else if (parts.length == 2) {
      final scoped = _findScopedEnd(text, macro.end, keyword);
      if (scoped != null) {
        value = text.substring(macro.end, scoped.contentEnd);
        pos = scoped.end;
      }
    } else {
      continue;
    }
    final trimmed = value?.trim() ?? '';
    if (trimmed.isNotEmpty) values.add(trimmed);
  }
  return values;
}
