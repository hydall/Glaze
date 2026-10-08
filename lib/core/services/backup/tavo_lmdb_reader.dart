import 'dart:convert';
import 'dart:typed_data';

/// Reader for the ObjectBox database inside a Tavo backup (`objectbox/data.mdb`).
///
/// ObjectBox keeps its data in LMDB and every object as a FlatBuffers table.
/// Nothing here is hardcoded per entity: ObjectBox stores its own schema
/// (entity names, property names, types and FlatBuffers slots) inside the
/// database, so the reader decodes that first and then every object through
/// it. A Tavo update that adds or moves a field changes the schema the file
/// carries, not this code.
///
/// The LMDB file is walked as a B-tree from the newest meta page. Scanning
/// every page instead would also pick up the copy-on-write leftovers LMDB keeps
/// in its free pages — stale versions of edited objects and objects that were
/// deleted.
class TavoDatabase {
  /// Objects per entity name, in id order. Each object maps the property name
  /// to its decoded value; a property the object does not carry is absent.
  final Map<String, List<Map<String, dynamic>>> entities;

  /// Standalone ToMany relations, keyed `Entity.relation`, as source object id
  /// to the ids of the objects it points at.
  final Map<String, Map<int, List<int>>> relations;

  const TavoDatabase({required this.entities, required this.relations});

  List<Map<String, dynamic>> rows(String entity) =>
      entities[entity] ?? const [];

  List<int> related(String relation, int sourceId) =>
      relations[relation]?[sourceId] ?? const [];
}

TavoDatabase parseTavoObjectBox(Uint8List mdb) {
  final lmdb = _Lmdb(mdb);
  final records = lmdb.records();

  final schema = <int, _Entity>{};
  for (final r in records) {
    if (r.key.length != 8 || _u32be(r.key, 0) != 0) continue;
    final entity = _Entity.tryParse(r.value);
    if (entity != null) schema[entity.id] = entity;
  }

  final entities = <String, List<Map<String, dynamic>>>{};
  final relationNames = <int, String>{};
  for (final e in schema.values) {
    entities[e.name] = [];
    for (final rel in e.relations) {
      relationNames[rel.id] = '${e.name}.${rel.name}';
    }
  }

  final relations = <String, Map<int, List<int>>>{};
  for (final r in records) {
    final prefix = r.key.length >= 4 ? _u32be(r.key, 0) : 0;
    final kind = prefix >> 24;
    if (kind == 0x18 && r.key.length == 8) {
      final entity = schema[(prefix & 0xffffff) >> 2];
      if (entity == null) continue;
      final row = entity.decode(r.value);
      row.putIfAbsent('id', () => _u32be(r.key, 4));
      entities[entity.name]!.add(row);
    } else if (kind == 0x08 && r.key.length == 12 && prefix & 3 == 0) {
      // Bit 1 marks the backlink copy of the same pair; the forward key
      // alone carries every edge.
      final name = relationNames[(prefix & 0xffffff) >> 2];
      if (name == null) continue;
      (relations[name] ??= {})
          .putIfAbsent(_u32be(r.key, 4), () => [])
          .add(_u32be(r.key, 8));
    }
  }

  return TavoDatabase(entities: entities, relations: relations);
}

int _u32be(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

class _Record {
  final Uint8List key;
  final Uint8List value;
  const _Record(this.key, this.value);
}

/// Minimal read-only LMDB walker for the 64-bit file layout ObjectBox writes.
class _Lmdb {
  static const _magic = 0xBEEFC0DE;
  static const _pageHeader = 16;
  static const _pBranch = 0x01;
  static const _pLeaf = 0x02;
  static const _fBigData = 0x01;
  static const _fSubData = 0x02;
  static const _fDupData = 0x04;

  final Uint8List _buf;
  final ByteData _bd;
  int _pageSize = 0;
  int _root = -1;

  /// Picks the newer of the two meta pages. Each holds the page size
  /// (`mm_dbs[FREE].md_pad`), the main database root (`mm_dbs[MAIN].md_root`)
  /// and the id of the transaction that wrote it.
  _Lmdb(this._buf) : _bd = ByteData.sublistView(_buf) {
    int? bestTxn;
    // The page size is only known from a meta page, so the second one is
    // looked for at every size LMDB can be built with.
    for (final at in const [0, 4096, 8192, 16384, 32768, 65536]) {
      final m = at + _pageHeader;
      if (m + 136 > _buf.length) continue;
      if (_bd.getUint32(m, Endian.little) != _magic) continue;
      final psize = _bd.getUint32(m + 24, Endian.little);
      if (at != 0 && at != psize) continue;
      final txn = _bd.getUint64(m + 128, Endian.little);
      if (bestTxn == null || txn > bestTxn) {
        bestTxn = txn;
        _pageSize = psize;
        _root = _bd.getUint64(m + 112, Endian.little);
      }
    }
    if (bestTxn == null || _pageSize == 0) {
      throw const FormatException('Not an LMDB file (no meta page).');
    }
  }

  List<_Record> records() {
    final out = <_Record>[];
    // An empty database has no root page (P_INVALID, all bits set).
    if (_root <= 1) return out;
    _walk(_root, out, 0);
    return out;
  }

  void _walk(int pgno, List<_Record> out, int depth) {
    if (depth > 64) throw const FormatException('LMDB tree is too deep.');
    final page = pgno * _pageSize;
    if (page + _pageHeader > _buf.length) {
      throw FormatException('LMDB page $pgno is out of range.');
    }
    final flags = _bd.getUint16(page + 10, Endian.little);
    final lower = _bd.getUint16(page + 12, Endian.little);
    final count = (lower - _pageHeader) >> 1;
    for (var i = 0; i < count; i++) {
      final node =
          page + _bd.getUint16(page + _pageHeader + i * 2, Endian.little);
      final lo = _bd.getUint16(node, Endian.little);
      final hi = _bd.getUint16(node + 2, Endian.little);
      final nodeFlags = _bd.getUint16(node + 4, Endian.little);
      final ksize = _bd.getUint16(node + 6, Endian.little);
      if (flags & _pBranch != 0) {
        _walk(lo | (hi << 16) | (nodeFlags << 32), out, depth + 1);
      } else if (flags & _pLeaf != 0) {
        if (nodeFlags & (_fSubData | _fDupData) != 0) continue;
        final key = Uint8List.sublistView(_buf, node + 8, node + 8 + ksize);
        final dsize = lo | (hi << 16);
        final dataAt = node + 8 + ksize;
        Uint8List value;
        if (nodeFlags & _fBigData != 0) {
          final overflow =
              _bd.getUint64(dataAt, Endian.little) * _pageSize + _pageHeader;
          if (overflow + dsize > _buf.length) {
            throw const FormatException('LMDB overflow page is out of range.');
          }
          value = Uint8List.sublistView(_buf, overflow, overflow + dsize);
        } else {
          value = Uint8List.sublistView(_buf, dataAt, dataAt + dsize);
        }
        out.add(_Record(key, value));
      }
    }
  }
}

/// Read helpers over one FlatBuffers buffer.
class _Fb {
  final Uint8List buf;
  final ByteData bd;
  _Fb(this.buf) : bd = ByteData.sublistView(buf);

  int u8(int o) => buf[o];
  int u16(int o) => bd.getUint16(o, Endian.little);
  int u32(int o) => bd.getUint32(o, Endian.little);

  int get root => u32(0);

  /// Absolute offsets of the fields present in the table at [table], by
  /// FlatBuffers field index.
  Map<int, int> fields(int table) {
    final vt = table - bd.getInt32(table, Endian.little);
    final count = (u16(vt) - 4) >> 1;
    final out = <int, int>{};
    for (var i = 0; i < count; i++) {
      final off = u16(vt + 4 + i * 2);
      if (off != 0) out[i] = table + off;
    }
    return out;
  }

  /// Absolute offset of the field stored at vtable byte offset [slot], or
  /// null when the table does not carry it.
  int? slot(int table, int slot) {
    final vt = table - bd.getInt32(table, Endian.little);
    if (slot >= u16(vt)) return null;
    final off = u16(vt + slot);
    return off == 0 ? null : table + off;
  }

  int deref(int o) => o + u32(o);

  String string(int o) {
    final p = deref(o);
    return utf8.decode(
      Uint8List.sublistView(buf, p + 4, p + 4 + u32(p)),
      allowMalformed: true,
    );
  }

  /// Start and length of the vector referenced at [o].
  (int, int) vector(int o) {
    final p = deref(o);
    return (p + 4, u32(p));
  }

  List<int> tables(int o) {
    final (start, len) = vector(o);
    return [for (var i = 0; i < len; i++) deref(start + i * 4)];
  }
}

class _Property {
  final String name;
  final int type;
  final int slot;
  const _Property(this.name, this.type, this.slot);
}

class _Relation {
  final int id;
  final String name;
  const _Relation(this.id, this.name);
}

class _Entity {
  final int id;
  final String name;
  final List<_Property> properties;
  final List<_Relation> relations;

  const _Entity(this.id, this.name, this.properties, this.relations);

  /// ObjectBox's internal schema record: entity id at field 1, name at 3,
  /// properties at 4 and standalone relations at 10. A property keeps its
  /// name at 6, type at 7 and FlatBuffers vtable offset at 8; a relation its
  /// id at 0 and name at 4.
  static _Entity? tryParse(Uint8List value) {
    try {
      final fb = _Fb(value);
      final f = fb.fields(fb.root);
      if (!f.containsKey(1) || !f.containsKey(3) || !f.containsKey(4)) {
        return null;
      }
      final properties = <_Property>[];
      for (final t in fb.tables(f[4]!)) {
        final pf = fb.fields(t);
        if (!pf.containsKey(6) || !pf.containsKey(7) || !pf.containsKey(8)) {
          continue;
        }
        properties.add(
          _Property(fb.string(pf[6]!), fb.u16(pf[7]!), fb.u16(pf[8]!)),
        );
      }
      final relations = <_Relation>[];
      if (f.containsKey(10)) {
        for (final t in fb.tables(f[10]!)) {
          final rf = fb.fields(t);
          if (!rf.containsKey(0) || !rf.containsKey(4)) continue;
          relations.add(_Relation(fb.u32(rf[0]!), fb.string(rf[4]!)));
        }
      }
      return _Entity(fb.u32(f[1]!), fb.string(f[3]!), properties, relations);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> decode(Uint8List value) {
    final fb = _Fb(value);
    final table = fb.root;
    final row = <String, dynamic>{};
    for (final p in properties) {
      final at = fb.slot(table, p.slot);
      if (at == null) continue;
      try {
        row[p.name] = _decodeValue(fb, at, p.type);
      } catch (_) {
        // One unreadable property should not cost the whole object.
      }
    }
    return row;
  }
}

/// ObjectBox `OBXPropertyType` values.
dynamic _decodeValue(_Fb fb, int at, int type) {
  final bd = fb.bd;
  switch (type) {
    case 1: // Bool
      return fb.u8(at) != 0;
    case 2: // Byte
      return bd.getInt8(at);
    case 3: // Short
      return bd.getInt16(at, Endian.little);
    case 4: // Char
      return fb.u16(at);
    case 5: // Int
      return bd.getInt32(at, Endian.little);
    case 6: // Long
    case 10: // Date (ms)
    case 11: // Relation (target id)
    case 12: // DateNano
      return bd.getInt64(at, Endian.little);
    case 7: // Float
      return bd.getFloat32(at, Endian.little);
    case 8: // Double
      return bd.getFloat64(at, Endian.little);
    case 9: // String
      return fb.string(at);
    case 13: // Flex
      final (start, len) = fb.vector(at);
      if (len == 0) return null;
      return decodeFlexBuffer(
        Uint8List.sublistView(fb.buf, start, start + len),
      );
    case 23: // ByteVector
      final (start, len) = fb.vector(at);
      return Uint8List.fromList(fb.buf.sublist(start, start + len));
    case 26: // IntVector
      final (start, len) = fb.vector(at);
      return [
        for (var i = 0; i < len; i++) bd.getInt32(start + i * 4, Endian.little),
      ];
    case 27: // LongVector
      final (start, len) = fb.vector(at);
      return [
        for (var i = 0; i < len; i++) bd.getInt64(start + i * 8, Endian.little),
      ];
    case 28: // FloatVector
      final (start, len) = fb.vector(at);
      return [
        for (var i = 0; i < len; i++)
          bd.getFloat32(start + i * 4, Endian.little),
      ];
    case 29: // DoubleVector
      final (start, len) = fb.vector(at);
      return [
        for (var i = 0; i < len; i++)
          bd.getFloat64(start + i * 8, Endian.little),
      ];
    case 30: // StringVector
      final (start, len) = fb.vector(at);
      return [for (var i = 0; i < len; i++) fb.string(start + i * 4)];
    default:
      return null;
  }
}

/// Decodes a FlexBuffers value — ObjectBox's `Flex` property type, which Tavo
/// uses for maps such as an endpoint's custom headers.
dynamic decodeFlexBuffer(Uint8List buf) {
  if (buf.length < 3) return null;
  final r = _FlexReader(buf);
  final rootWidth = buf[buf.length - 1];
  final packed = buf[buf.length - 2];
  return r.read(buf.length - 2 - rootWidth, rootWidth, packed);
}

class _FlexReader {
  final Uint8List buf;
  final ByteData bd;
  _FlexReader(this.buf) : bd = ByteData.sublistView(buf);

  int uint(int o, int w) => switch (w) {
    1 => buf[o],
    2 => bd.getUint16(o, Endian.little),
    4 => bd.getUint32(o, Endian.little),
    _ => bd.getUint64(o, Endian.little),
  };

  int sint(int o, int w) => switch (w) {
    1 => bd.getInt8(o),
    2 => bd.getInt16(o, Endian.little),
    4 => bd.getInt32(o, Endian.little),
    _ => bd.getInt64(o, Endian.little),
  };

  double float(int o, int w) => w == 4
      ? bd.getFloat32(o, Endian.little)
      : bd.getFloat64(o, Endian.little);

  String key(int o) {
    var end = o;
    while (end < buf.length && buf[end] != 0) {
      end++;
    }
    return utf8.decode(
      Uint8List.sublistView(buf, o, end),
      allowMalformed: true,
    );
  }

  /// Reads the value stored at [o] in a slot [parentWidth] bytes wide.
  dynamic read(int o, int parentWidth, int packed) {
    final type = packed >> 2;
    final width = 1 << (packed & 3);
    switch (type) {
      case 0:
        return null;
      case 1:
        return sint(o, parentWidth);
      case 2:
        return uint(o, parentWidth);
      case 3:
        return float(o, parentWidth);
      case 26:
        return uint(o, parentWidth) != 0;
    }
    final target = o - uint(o, parentWidth);
    switch (type) {
      case 4: // Key
        return key(target);
      case 5: // String
        final len = uint(target - width, width);
        return utf8.decode(
          Uint8List.sublistView(buf, target, target + len),
          allowMalformed: true,
        );
      case 6:
        return sint(target, width);
      case 7:
        return uint(target, width);
      case 8:
        return float(target, width);
      case 9: // Map
        final len = uint(target - width, width);
        final keysAt = target - 3 * width;
        final keys = keysAt - uint(keysAt, width);
        final keyWidth = uint(target - 2 * width, width);
        final map = <String, dynamic>{};
        for (var i = 0; i < len; i++) {
          final k = keys + i * keyWidth;
          map[key(k - uint(k, keyWidth))] = read(
            target + i * width,
            width,
            buf[target + len * width + i],
          );
        }
        return map;
      case 10: // Vector
        final len = uint(target - width, width);
        return [
          for (var i = 0; i < len; i++)
            read(target + i * width, width, buf[target + len * width + i]),
        ];
      case 11: // VectorInt
      case 12: // VectorUInt
      case 13: // VectorFloat
      case 14: // VectorKey
      case 15: // VectorString (deprecated)
      case 36: // VectorBool
        final len = uint(target - width, width);
        final elementType = switch (type) {
          11 => 1,
          12 => 2,
          13 => 3,
          14 => 4,
          15 => 5,
          _ => 26,
        };
        return [
          for (var i = 0; i < len; i++)
            read(target + i * width, width, (elementType << 2) | (packed & 3)),
        ];
      case 25: // Blob
        final len = uint(target - width, width);
        return Uint8List.fromList(buf.sublist(target, target + len));
      default:
        return null;
    }
  }
}
