import 'package:flutter_riverpod/legacy.dart';

final editingMessageIdProvider = StateProvider.family<String?, String>(
  (ref, charId) => null,
);
