import 'package:flutter_riverpod/legacy.dart';

import '../../../core/llm/context_calculator.dart';

final cachedTokenBreakdownProvider =
    StateProvider.family<TokenBreakdown?, String>((ref, _) => null);

final lastVectorLoreTokensProvider = StateProvider.family<int, String>(
  (ref, _) => 0,
);
