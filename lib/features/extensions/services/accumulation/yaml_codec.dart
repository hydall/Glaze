import 'package:yaml/yaml.dart';

/// YAML in and out for accumulation blocks, standing in for the `js-yaml`
/// `load` / `dump` pair the original extension uses.

/// Parses [source] into plain Dart values: maps with string keys, lists and
/// scalars. A blank source is `null`. Throws [YamlException] on bad YAML.
Object? parseYaml(String source) {
  final text = _stripFence(source);
  if (text.trim().isEmpty) return null;
  return _plain(loadYaml(text));
}

/// A model often wraps its YAML in a markdown fence; the fence is not part
/// of the document.
String _stripFence(String source) {
  final match = RegExp(
    r'^\s*```[\w-]*[ \t]*\r?\n([\s\S]*?)\r?\n\s*```\s*$',
  ).firstMatch(source);
  return match?.group(1) ?? source;
}

Object? _plain(Object? node) {
  if (node is YamlMap || node is Map) {
    return <String, Object?>{
      for (final e in (node as Map).entries) '${e.key}': _plain(e.value),
    };
  }
  if (node is YamlList || node is List) {
    return [for (final e in node as List) _plain(e)];
  }
  if (node is YamlScalar) return node.value;
  return node;
}

/// Writes [value] as block-style YAML the way `js-yaml`'s `dump` with an
/// unlimited line width does: nested mappings and sequences indented by two,
/// strings plain where YAML reads them back unchanged and quoted otherwise,
/// multi-line strings as literal blocks.
String dumpYaml(Object? value) {
  if (value is Map && value.isNotEmpty) {
    final out = StringBuffer();
    _map(value, 0, out);
    return out.toString();
  }
  if (value is List && value.isNotEmpty) {
    final out = StringBuffer();
    _list(value, 0, out);
    return out.toString();
  }
  return '${_scalar(value)}\n';
}

void _map(Map<Object?, Object?> map, int indent, StringBuffer out) {
  for (final entry in map.entries) {
    out
      ..write(' ' * indent)
      ..write(_scalar('${entry.key}'))
      ..write(':');
    _afterKey(entry.value, indent, out);
  }
}

void _afterKey(Object? value, int indent, StringBuffer out) {
  if (value is Map && value.isNotEmpty) {
    out.writeln();
    _map(value, indent + 2, out);
  } else if (value is List && value.isNotEmpty) {
    out.writeln();
    _list(value, indent + 2, out);
  } else if (value is String && _literalBlock(value) != null) {
    out
      ..write(' ')
      ..write(_literalBlock(value)!.header);
    _blockLines(value, indent + 2, out);
  } else {
    out
      ..write(' ')
      ..writeln(_scalar(value));
  }
}

void _list(List<Object?> list, int indent, StringBuffer out) {
  for (final item in list) {
    out
      ..write(' ' * indent)
      ..write('-');
    final nested = StringBuffer();
    if (item is Map && item.isNotEmpty) {
      _map(item, indent + 2, nested);
    } else if (item is List && item.isNotEmpty) {
      _list(item, indent + 2, nested);
    }
    if (nested.isNotEmpty) {
      // The first line of a nested collection shares the dash's line.
      out
        ..write(' ')
        ..write(nested.toString().substring(indent + 2));
    } else if (item is String && _literalBlock(item) != null) {
      out
        ..write(' ')
        ..write(_literalBlock(item)!.header);
      _blockLines(item, indent + 2, out);
    } else {
      out
        ..write(' ')
        ..writeln(_scalar(item));
    }
  }
}

/// The header for writing [s] as a literal block (`|`, `|-` or `|+`), or
/// `null` when it has no newline or cannot be written that way faithfully.
({String header})? _literalBlock(String s) {
  if (!s.contains('\n')) return null;
  if (_needsEscape.hasMatch(s.replaceAll('\n', ''))) return null;
  // A first line opening with a space would need an indentation indicator.
  if (s.startsWith(' ') || s.startsWith('\n')) return null;
  if (s.split('\n').any((l) => l.endsWith(' ') || l.endsWith('\t'))) {
    return null;
  }
  final chomp = s.endsWith('\n\n')
      ? '+'
      : s.endsWith('\n')
      ? ''
      : '-';
  return (header: '|$chomp\n');
}

void _blockLines(String s, int indent, StringBuffer out) {
  var body = s;
  if (body.endsWith('\n')) body = body.substring(0, body.length - 1);
  for (final line in body.split('\n')) {
    if (line.isEmpty) {
      out.writeln();
    } else {
      out
        ..write(' ' * indent)
        ..writeln(line);
    }
  }
}

final _needsEscape = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\uFEFF]');

/// Words YAML would read as something other than a string.
final _reserved = RegExp(
  r'^(?:~|null|true|false|yes|no|on|off|y|n)$',
  caseSensitive: false,
);
final _numberLike = RegExp(
  r'^[-+]?(?:\.?\d[\d_]*(?:\.[\d_]*)?(?:[eE][-+]?\d+)?|0x[0-9a-fA-F_]+|0o?[0-7_]+|0b[01_]+|\.(?:inf|nan))$',
  caseSensitive: false,
);

String _scalar(Object? value) {
  if (value == null) return 'null';
  if (value is bool) return '$value';
  if (value is int) return '$value';
  if (value is double) {
    if (value.isNaN) return '.nan';
    if (value.isInfinite) return value > 0 ? '.inf' : '-.inf';
    if (value == value.truncateToDouble() && value.abs() < 1e21) {
      return value.toInt().toString();
    }
    return '$value';
  }
  if (value is Map) return '{}';
  if (value is List) return '[]';
  final s = '$value';
  if (_needsEscape.hasMatch(s) || s.contains('\n') || s.contains('\t')) {
    return _doubleQuoted(s);
  }
  if (_isPlainSafe(s)) return s;
  return "'${s.replaceAll("'", "''")}'";
}

bool _isPlainSafe(String s) {
  if (s.isEmpty) return false;
  if (s != s.trim()) return false;
  if (_reserved.hasMatch(s) || _numberLike.hasMatch(s)) return false;
  if (RegExp(r'''^[-?:,\[\]{}#&*!|>'"%@`]''').hasMatch(s)) {
    // `-`, `?` and `:` only start an indicator when a space follows.
    final first = s[0];
    final second = s.length > 1 ? s[1] : ' ';
    if (!('-?:'.contains(first) && second != ' ')) return false;
  }
  if (s.contains(': ') || s.contains(' #') || s.endsWith(':')) return false;
  return true;
}

String _doubleQuoted(String s) {
  final out = StringBuffer('"');
  for (final rune in s.runes) {
    switch (rune) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x0A:
        out.write(r'\n');
      case 0x09:
        out.write(r'\t');
      case 0x0D:
        out.write(r'\r');
      default:
        if (rune < 0x20 || rune == 0x7F || rune == 0xFEFF) {
          out.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
        } else {
          out.writeCharCode(rune);
        }
    }
  }
  out.write('"');
  return out.toString();
}
