import 'package:collection/collection.dart';

/// MongoDB-style update operators over a plain JSON-like document, the part
/// of `mingo` the original extension's accumulation blocks rely on
/// (`applyMongoUpdate` in `dataUtils.js`).
///
/// Supported: `$set`, `$unset`, `$inc`, `$mul`, `$min`, `$max`, `$rename`,
/// `$push` (with `$each`, `$position`, `$sort`, `$slice`), `$addToSet`,
/// `$pop`, `$pull`, `$pullAll`, `$currentDate` and `$bit`. Paths use dot
/// notation, with numeric parts indexing lists, `$[]` for every element and
/// `$[name]` for the elements an `arrayFilters` entry matches. A top-level
/// `condition` is a query the document must match for the update to apply.

/// An update the document cannot take: an unknown operator, a number
/// operator on a non-number, a list operator on a non-list.
class MongoUpdateError implements Exception {
  const MongoUpdateError(this.message);

  final String message;

  @override
  String toString() => 'MongoUpdateError: $message';
}

const _deepEq = DeepCollectionEquality();

/// Applies [update] to [doc] in place and returns it.
///
/// As in the original, keys of [update] that are not operators are folded
/// into `$set`, and a list given to `$push` or `$addToSet` adds each of its
/// items. Anything other than a map leaves [doc] as it is.
Map<String, Object?> applyMongoUpdate(
  Map<String, Object?> doc,
  Object? update,
) {
  if (update is! Map) return doc;
  final filters = update['arrayFilters'];
  final condition = update['condition'];

  final modifier = <String, Map<String, Object?>>{};
  for (final entry in update.entries) {
    final key = '${entry.key}';
    if (key == 'arrayFilters' || key == 'condition' || key == 'options') {
      continue;
    }
    if (key.startsWith(r'$')) {
      final value = entry.value;
      if (value is! Map) {
        throw MongoUpdateError('Modifiers operate on fields: $key');
      }
      (modifier[key] ??= {}).addAll({
        for (final field in value.entries) '${field.key}': field.value,
      });
    } else {
      (modifier[r'$set'] ??= {})[key] = entry.value;
    }
  }

  if (condition is Map && !matchesQuery(doc, condition)) return doc;
  // Plain, growable collections throughout, so any value fits anywhere.
  for (final key in doc.keys.toList()) {
    doc[key] = _copy(doc[key]);
  }
  final arrayFilters = _ArrayFilters.parse(filters);

  for (final op in modifier.entries) {
    for (final field in op.value.entries) {
      var value = field.value;
      if ((op.key == r'$push' || op.key == r'$addToSet') && value is List) {
        value = <String, Object?>{r'$each': value};
      }
      _applyOperator(doc, op.key, field.key, value, arrayFilters);
    }
  }
  return doc;
}

void _applyOperator(
  Map<String, Object?> doc,
  String op,
  String path,
  Object? value,
  _ArrayFilters filters,
) {
  final parts = path.split('.');
  void walk(_Leaf leaf, {bool create = true}) =>
      _descend(doc, parts, filters, leaf, create: create);

  switch (op) {
    case r'$set':
      walk((c, k) => _put(c, k, _copy(value)));
    case r'$unset':
      walk((c, k) {
        if (!_has(c, k)) return;
        if (c is List) {
          c[k as int] = null;
        } else {
          (c as Map).remove(k);
        }
      }, create: false);
    case r'$inc':
      final by = _number(op, path, value);
      walk((c, k) {
        final current = _get(c, k);
        if (!_has(c, k) || current == null) {
          _put(c, k, by);
        } else if (current is num) {
          _put(c, k, current + by);
        } else {
          throw MongoUpdateError('Cannot apply \$inc to a non-number at $path');
        }
      });
    case r'$mul':
      final by = _number(op, path, value);
      walk((c, k) {
        final current = _get(c, k);
        if (!_has(c, k) || current == null) {
          _put(c, k, 0);
        } else if (current is num) {
          _put(c, k, current * by);
        } else {
          throw MongoUpdateError('Cannot apply \$mul to a non-number at $path');
        }
      });
    case r'$min' || r'$max':
      walk((c, k) {
        if (!_has(c, k)) {
          _put(c, k, _copy(value));
          return;
        }
        final cmp = compareValues(value, _get(c, k));
        if (cmp == null) return;
        if (op == r'$min' ? cmp < 0 : cmp > 0) _put(c, k, _copy(value));
      });
    case r'$rename':
      if (value is! String || value.isEmpty) {
        throw MongoUpdateError('\$rename target for $path must be a string');
      }
      Object? moved;
      var found = false;
      walk((c, k) {
        if (c is! Map || !c.containsKey(k)) return;
        found = true;
        moved = c.remove(k);
      }, create: false);
      if (found) {
        _descend(
          doc,
          value.split('.'),
          filters,
          (c, k) => _put(c, k, moved),
          create: true,
        );
      }
    case r'$push':
      final spec = _pushSpec(value);
      walk((c, k) {
        final current = _get(c, k);
        if (!_has(c, k) || current == null) {
          _put(c, k, spec.applyTo([]));
        } else if (current is List) {
          _put(c, k, spec.applyTo(current));
        } else {
          throw MongoUpdateError('Cannot apply \$push to a non-list at $path');
        }
      });
    case r'$addToSet':
      final items = value is Map && value.containsKey(r'$each')
          ? List<Object?>.from(value[r'$each'] as List? ?? const [])
          : [value];
      walk((c, k) {
        final current = _get(c, k);
        final List<Object?> list;
        if (!_has(c, k) || current == null) {
          list = [];
        } else if (current is List) {
          list = current;
        } else {
          throw MongoUpdateError(
            'Cannot apply \$addToSet to a non-list at $path',
          );
        }
        for (final item in items) {
          if (!list.any((e) => _deepEq.equals(e, item))) list.add(_copy(item));
        }
        _put(c, k, list);
      });
    case r'$pop':
      walk((c, k) {
        final current = _get(c, k);
        if (current is! List || current.isEmpty) return;
        if (value == -1) {
          current.removeAt(0);
        } else {
          current.removeLast();
        }
      }, create: false);
    case r'$pull':
      final test = _pullTest(value);
      walk((c, k) {
        final current = _get(c, k);
        if (current is! List) return;
        current.removeWhere(test);
      }, create: false);
    case r'$pullAll':
      if (value is! List) {
        throw MongoUpdateError('\$pullAll for $path needs a list');
      }
      walk((c, k) {
        final current = _get(c, k);
        if (current is! List) return;
        current.removeWhere((e) => value.any((v) => _deepEq.equals(e, v)));
      }, create: false);
    case r'$currentDate':
      final timestamp = value is Map && value[r'$type'] == 'timestamp';
      final now = DateTime.now();
      walk(
        (c, k) => _put(
          c,
          k,
          timestamp
              ? now.millisecondsSinceEpoch
              : now.toUtc().toIso8601String(),
        ),
      );
    case r'$bit':
      if (value is! Map) throw MongoUpdateError('\$bit for $path needs a map');
      walk((c, k) {
        var current = _get(c, k) ?? 0;
        if (current is! int) {
          throw MongoUpdateError(
            'Cannot apply \$bit to a non-integer at $path',
          );
        }
        for (final entry in value.entries) {
          final operand = entry.value;
          if (operand is! int) {
            throw MongoUpdateError(
              '\$bit operand for $path must be an integer',
            );
          }
          current = switch ('${entry.key}') {
            'and' => (current as int) & operand,
            'or' => (current as int) | operand,
            'xor' => (current as int) ^ operand,
            final other => throw MongoUpdateError('Unknown \$bit op "$other"'),
          };
        }
        _put(c, k, current);
      });
    default:
      throw MongoUpdateError('Unknown update operator "$op"');
  }
}

num _number(String op, String path, Object? value) {
  if (value is num) return value;
  throw MongoUpdateError('$op for $path needs a number, got "$value"');
}

typedef _Leaf = void Function(Object container, Object key);

/// Walks [parts] from [container] and calls [leaf] with the container and key
/// of every place the path ends at. With [create], missing maps on the way
/// are made; without it a missing branch simply ends the walk.
void _descend(
  Object container,
  List<String> parts,
  _ArrayFilters filters,
  _Leaf leaf, {
  required bool create,
}) {
  final part = parts.first;
  final rest = parts.sublist(1);

  final Iterable<Object> keys;
  if (part == r'$') {
    throw const MongoUpdateError(
      r'The positional operator "$" is not supported; use "$[]" or arrayFilters',
    );
  } else if (part == r'$[]' || (part.startsWith(r'$[') && part.endsWith(']'))) {
    if (container is! List) return;
    final name = part.substring(2, part.length - 1);
    keys = [
      for (var i = 0; i < container.length; i++)
        if (name.isEmpty || filters.matches(name, container[i])) i,
    ];
  } else if (container is List) {
    final index = int.tryParse(part);
    if (index == null || index < 0) {
      throw MongoUpdateError('Cannot use the part "$part" to index a list');
    }
    keys = [index];
  } else {
    keys = [part];
  }

  for (final key in keys) {
    if (rest.isEmpty) {
      leaf(container, key);
      continue;
    }
    var child = _get(container, key);
    if (child is! Map && child is! List) {
      if (!create) continue;
      if (child != null) {
        throw MongoUpdateError(
          'Cannot create field "${rest.first}" in a non-container value',
        );
      }
      child = <String, Object?>{};
      _put(container, key, child);
    }
    _descend(child!, rest, filters, leaf, create: create);
  }
}

bool _has(Object container, Object key) {
  if (container is Map) return container.containsKey(key);
  if (container is List) return (key as int) < container.length;
  return false;
}

Object? _get(Object container, Object key) {
  if (container is Map) return container[key];
  if (container is List) {
    final index = key as int;
    return index < container.length ? container[index] : null;
  }
  return null;
}

void _put(Object container, Object key, Object? value) {
  if (container is Map) {
    container[key] = value;
  } else if (container is List) {
    final index = key as int;
    while (container.length <= index) {
      container.add(null);
    }
    container[index] = value;
  }
}

Object? _copy(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final e in value.entries) '${e.key}': _copy(e.value),
    };
  }
  if (value is List) return [for (final e in value) _copy(e)];
  return value;
}

class _PushSpec {
  const _PushSpec(this.each, {this.position, this.slice, this.sort});

  final List<Object?> each;
  final int? position;
  final int? slice;
  final Object? sort;

  List<Object?> applyTo(List<Object?> list) {
    final items = [for (final e in each) _copy(e)];
    var at = position ?? list.length;
    if (at < 0) at = list.length + at;
    list.insertAll(at.clamp(0, list.length), items);
    final sortSpec = sort;
    if (sortSpec != null) {
      final field = sortSpec is Map && sortSpec.isNotEmpty
          ? '${sortSpec.keys.first}'
          : null;
      final direction =
          (field != null ? sortSpec as Map : null)?[field] ?? sortSpec;
      final sign = direction is num && direction < 0 ? -1 : 1;
      Object? keyOf(Object? e) =>
          field == null ? e : resolvePath(e, field.split('.')).firstOrNull;
      mergeSort(
        list,
        compare: (a, b) => sign * (compareValues(keyOf(a), keyOf(b)) ?? 0),
      );
    }
    final cut = slice;
    if (cut != null) {
      if (cut < 0) {
        if (list.length > -cut) list.removeRange(0, list.length + cut);
      } else if (list.length > cut) {
        list.removeRange(cut, list.length);
      }
    }
    return list;
  }
}

_PushSpec _pushSpec(Object? value) {
  const modifiers = {r'$each', r'$slice', r'$sort', r'$position'};
  if (value is Map && value.keys.any(modifiers.contains)) {
    final each = value[r'$each'];
    return _PushSpec(
      each is List ? List<Object?>.from(each) : [each],
      position: (value[r'$position'] as num?)?.toInt(),
      slice: (value[r'$slice'] as num?)?.toInt(),
      sort: value[r'$sort'],
    );
  }
  return _PushSpec([value]);
}

/// The element test `$pull` uses: a query over the element when [condition]
/// is a plain map of fields, a condition on the element itself otherwise —
/// a bare value or a map of operators.
bool Function(Object?) _pullTest(Object? condition) {
  if (condition is Map && !condition.keys.any((k) => '$k'.startsWith(r'$'))) {
    return (e) => e is Map && matchesQuery(e, condition);
  }
  return (e) => matchesCondition([e], condition);
}

/// The `arrayFilters` of an update, grouped by the identifier each filter
/// names (`elem` in `"elem.name": "Village"`).
class _ArrayFilters {
  const _ArrayFilters(this._byName);

  final Map<String, Map<String, Object?>> _byName;

  static _ArrayFilters parse(Object? raw) {
    final byName = <String, Map<String, Object?>>{};
    if (raw is List) {
      for (final filter in raw) {
        if (filter is! Map) continue;
        for (final entry in filter.entries) {
          final key = '${entry.key}';
          final dot = key.indexOf('.');
          final name = dot < 0 ? key : key.substring(0, dot);
          final path = dot < 0 ? '' : key.substring(dot + 1);
          (byName[name] ??= {})[path] = entry.value;
        }
      }
    }
    return _ArrayFilters(byName);
  }

  bool matches(String name, Object? element) {
    final filter = _byName[name];
    if (filter == null) {
      throw MongoUpdateError('No array filter found for identifier "$name"');
    }
    return filter.entries.every(
      (e) => e.key.isEmpty
          ? matchesCondition([element], e.value)
          : _matchesField(element, e.key, e.value),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Queries
// ─────────────────────────────────────────────────────────────────────────────

/// Whether [doc] matches the MongoDB-style [query].
bool matchesQuery(Object? doc, Map<Object?, Object?> query) {
  for (final entry in query.entries) {
    final key = '${entry.key}';
    final value = entry.value;
    final ok = switch (key) {
      r'$and' => _subQueries(value).every((q) => matchesQuery(doc, q)),
      r'$or' => _subQueries(value).any((q) => matchesQuery(doc, q)),
      r'$nor' => !_subQueries(value).any((q) => matchesQuery(doc, q)),
      _ when key.startsWith(r'$') => throw MongoUpdateError(
        'Unknown query operator "$key"',
      ),
      _ => _matchesField(doc, key, value),
    };
    if (!ok) return false;
  }
  return true;
}

Iterable<Map<Object?, Object?>> _subQueries(Object? value) {
  if (value is! List) {
    throw const MongoUpdateError('Logical operators need a list');
  }
  return value.whereType<Map<Object?, Object?>>();
}

bool _matchesField(Object? doc, String path, Object? condition) =>
    matchesCondition(resolvePath(doc, path.split('.')), condition);

/// Every value [parts] reaches from [node]. As in MongoDB, a non-numeric part
/// applied to a list reaches into each of its elements.
List<Object?> resolvePath(Object? node, List<String> parts) {
  if (parts.isEmpty) return [node];
  final part = parts.first;
  final rest = parts.sublist(1);
  if (node is Map) {
    if (!node.containsKey(part)) return const [];
    return resolvePath(node[part], rest);
  }
  if (node is List) {
    final index = int.tryParse(part);
    if (index != null) {
      return index < node.length ? resolvePath(node[index], rest) : const [];
    }
    return [for (final e in node) ...resolvePath(e, parts)];
  }
  return const [];
}

/// Whether any of [values] — the values a path reached, empty when it
/// reached nothing — satisfies [condition]: a map of operators, or a value
/// to equal (a list value also matches when one of its elements does).
bool matchesCondition(List<Object?> values, Object? condition) {
  if (condition is Map &&
      condition.isNotEmpty &&
      condition.keys.every((k) => '$k'.startsWith(r'$'))) {
    final options = condition[r'$options'];
    return condition.entries
        .where((e) => e.key != r'$options')
        .every((e) => _operator(values, '${e.key}', e.value, options));
  }
  return _equalsAny(values, condition);
}

bool _equalsAny(List<Object?> values, Object? target) {
  if (values.isEmpty) return target == null;
  return values.any(
    (v) =>
        _deepEq.equals(v, target) ||
        (v is List && v.any((e) => _deepEq.equals(e, target))),
  );
}

/// [values] with each list also contributing its elements, for the
/// comparison operators.
Iterable<Object?> _flat(List<Object?> values) sync* {
  for (final v in values) {
    yield v;
    if (v is List) yield* v;
  }
}

bool _operator(List<Object?> values, String op, Object? arg, Object? options) {
  bool compare(bool Function(int c) test) => _flat(values).any((v) {
    final c = compareValues(v, arg);
    return c != null && test(c);
  });

  switch (op) {
    case r'$eq':
      return _equalsAny(values, arg);
    case r'$ne':
      return !_equalsAny(values, arg);
    case r'$gt':
      return compare((c) => c > 0);
    case r'$gte':
      return compare((c) => c >= 0);
    case r'$lt':
      return compare((c) => c < 0);
    case r'$lte':
      return compare((c) => c <= 0);
    case r'$in':
      if (arg is! List) throw const MongoUpdateError(r'$in needs a list');
      return arg.any((a) => _equalsAny(values, a));
    case r'$nin':
      if (arg is! List) throw const MongoUpdateError(r'$nin needs a list');
      return !arg.any((a) => _equalsAny(values, a));
    case r'$exists':
      final present = values.isNotEmpty;
      return (arg == true || (arg is num && arg != 0)) ? present : !present;
    case r'$regex':
      final flags = options is String ? options : '';
      final regex = RegExp(
        '$arg',
        caseSensitive: !flags.contains('i'),
        multiLine: flags.contains('m'),
        dotAll: flags.contains('s'),
      );
      return _flat(values).any((v) => v is String && regex.hasMatch(v));
    case r'$size':
      return values.any((v) => v is List && v.length == arg);
    case r'$all':
      if (arg is! List) throw const MongoUpdateError(r'$all needs a list');
      return values.any(
        (v) =>
            v is List && arg.every((a) => v.any((e) => _deepEq.equals(e, a))),
      );
    case r'$elemMatch':
      if (arg is! Map) throw const MongoUpdateError(r'$elemMatch needs a map');
      final onFields = !arg.keys.any((k) => '$k'.startsWith(r'$'));
      return values.any(
        (v) =>
            v is List &&
            v.any(
              (e) => onFields
                  ? e is Map && matchesQuery(e, arg)
                  : matchesCondition([e], arg),
            ),
      );
    case r'$not':
      return !matchesCondition(values, arg);
    case r'$mod':
      if (arg is! List || arg.length != 2) {
        throw const MongoUpdateError(r'$mod needs [divisor, remainder]');
      }
      final divisor = arg[0], remainder = arg[1];
      if (divisor is! num || remainder is! num || divisor == 0) return false;
      return _flat(
        values,
      ).any((v) => v is num && v.remainder(divisor) == remainder);
    default:
      throw MongoUpdateError('Unknown query operator "$op"');
  }
}

/// Orders two values of the same kind — numbers, strings or booleans — and
/// returns `null` for any other pair, which no range test then matches.
int? compareValues(Object? a, Object? b) {
  if (a is num && b is num) return a.compareTo(b);
  if (a is String && b is String) return a.compareTo(b);
  if (a is bool && b is bool) return a == b ? 0 : (a ? 1 : -1);
  return null;
}
