mixin TypeConverters {
  int? toInt(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    if (value is double) return value.toInt();
    return null;
  }

  double? toDouble(dynamic value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  List<int> toIntList(dynamic value) {
    if (value is List) {
      return value.map((e) {
        if (e is int) return e;
        if (e is num) return e.toInt();
        return int.tryParse(e.toString()) ?? 0;
      }).toList();
    }
    return [1, 2];
  }

  List<String> toStringList(dynamic value) {
    if (value is List) return value.map((e) => e.toString()).toList();
    if (value is String && value.isNotEmpty) {
      return value
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return [];
  }

  String joinTrimStrings(dynamic value) {
    if (value is List) return value.map((e) => e.toString()).join('\n');
    return '';
  }
}
