import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/prompt_build_providers.dart';
import '../../../shared/widgets/glaze_toast.dart';

class LorebookVectorSearchDiagnosticListener extends ConsumerWidget {
  final Widget child;

  const LorebookVectorSearchDiagnosticListener({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(lorebookVectorSearchDiagnosticProvider, (previous, next) {
      if (next == null) return;
      GlazeToast.showWithoutContext(
        'Vector search failed — try reindexing embeddings',
        duration: 4000,
        position: ToastPosition.top,
        isError: true,
      );
    });
    return child;
  }
}
