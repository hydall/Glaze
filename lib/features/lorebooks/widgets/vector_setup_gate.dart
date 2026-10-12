import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/embedding_service.dart';
import '../../../core/services/api_connection_tester.dart';
import '../../../core/state/lorebook_embedding_provider.dart';
import '../../../core/utils/error_format.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../settings/api_list_provider.dart';
import '../../settings/api_settings_screen.dart';

/// Sends one test request to an embedding connection and remembers the ones
/// that answered, so turning vector features on costs one request per
/// connection and session.
class EmbeddingProbe {
  final Future<ApiTestResult> Function(EmbeddingConfig config) _test;
  final _verified = <String>{};

  EmbeddingProbe([Future<ApiTestResult> Function(EmbeddingConfig config)? test])
    : _test = test ?? _testConnection;

  static Future<ApiTestResult> _testConnection(EmbeddingConfig config) =>
      ApiConnectionTester().testEmbedding(
        endpoint: config.endpoint,
        apiKey: config.apiKey,
        model: config.model,
      );

  static String _key(EmbeddingConfig config) =>
      '${config.endpoint}\n${config.model}\n${config.apiKey.hashCode}';

  bool isVerified(EmbeddingConfig config) => _verified.contains(_key(config));

  /// Null when the connection works, otherwise the error it failed with.
  Future<Object?> check(EmbeddingConfig config) async {
    final result = await _test(config);
    switch (result) {
      case ApiTestSuccess():
        _verified.add(_key(config));
        return null;
      case ApiTestFailure(:final error):
        // A rate limit means the endpoint, key and model were all accepted.
        if (error is RateLimitException) {
          _verified.add(_key(config));
          return null;
        }
        return error;
    }
  }
}

final embeddingProbeProvider = Provider<EmbeddingProbe>(
  (ref) => EmbeddingProbe(),
);

/// Checks that vector search can actually run before a lorebook vector
/// feature is switched on: embeddings are enabled, have an endpoint and a
/// model, and the connection answers a test request.
///
/// On any failure the user is shown [showVectorSetupSheet], which leads to the
/// Embeddings tab of the API settings, and false is returned so the caller
/// leaves the feature off.
Future<bool> ensureVectorsReady(BuildContext context, WidgetRef ref) async {
  await ref.read(apiListProvider.future);
  if (!context.mounted) return false;
  if (!ref.read(embeddingConfiguredProvider)) {
    showVectorSetupSheet(context);
    return false;
  }
  final config = ref.read(embeddingConfigProvider);
  final probe = ref.read(embeddingProbeProvider);
  if (probe.isVerified(config)) return true;

  GlazeToast.show(context, 'vectors_checking'.tr());
  final error = await probe.check(config);
  if (!context.mounted) return false;
  if (error != null) {
    showVectorSetupSheet(context, error: error);
    return false;
  }
  return true;
}

/// Explains why vectors cannot run and offers to open the embedding settings.
/// [error] set means the connection is configured but failed its probe.
void showVectorSetupSheet(BuildContext context, {Object? error}) {
  GlazeBottomSheet.show<void>(
    context,
    title: error == null
        ? 'vectors_setup_title'.tr()
        : 'vectors_broken_title'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: error == null ? Icons.hub_outlined : Icons.link_off_rounded,
      description: error == null
          ? 'vectors_setup_desc'.tr()
          : 'vectors_broken_desc'.tr(namedArgs: {'error': formatError(error)}),
      buttonText: 'vectors_setup_open'.tr(),
      onButtonTap: () {
        Navigator.of(context, rootNavigator: true).pop();
        unawaited(openEmbeddingSetup(context));
      },
    ),
  );
}

/// Opens the API settings on their Embeddings tab.
Future<void> openEmbeddingSetup(BuildContext context) =>
    showApiSettingsSheet(context, focusSection: ApiSettingsSection.embeddings);

/// A row for a vector settings group while embeddings are not set up: says
/// so, and opens the embedding settings on tap.
class VectorSetupItem extends StatelessWidget {
  const VectorSetupItem({super.key});

  @override
  Widget build(BuildContext context) {
    return MenuItem(
      icon: Icons.hub_outlined,
      label: 'vectors_setup_open'.tr(),
      subtitle: 'vectors_setup_row_hint'.tr(),
      onTap: () => unawaited(openEmbeddingSetup(context)),
    );
  }
}
