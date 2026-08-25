import 'package:easy_localization/easy_localization.dart';

import '../../../core/utils/error_format.dart';
import 'catalog_error_source.dart';
import 'janitor_lorebook_rebuilder.dart';
import 'janitor_webview_proxy.dart';

export 'catalog_error_source.dart';

/// A failure with the party it came from and a message worth reading.
class LabeledError {
  final CatalogErrorSource source;
  final String message;

  const LabeledError(this.source, this.message);

  String get label => source.label;

  /// One-line form for a toast, where there is no header to carry the label.
  String get inline => '$label: $message';
}

/// Turns any exception raised in the capture/build flow into a labelled,
/// human-readable failure.
///
/// The message goes through the shared [formatError], so a provider's
/// `DioException` reads as `HTTP 401: Invalid API key` — the same wording the
/// chat writes into a failed message — instead of Dio's multi-paragraph dump.
/// [fallback] names the party for errors that carry no source of their own: the
/// capture stage only ever talks to Janitor.AI, the build stage only to the
/// provider.
LabeledError describeCatalogError(
  Object error, {
  CatalogErrorSource fallback = CatalogErrorSource.glaze,
}) {
  if (error is JanitorAuthException) {
    return LabeledError(
      CatalogErrorSource.janitor,
      'catalog_janitor_session_expired'.tr(),
    );
  }
  if (error is JanitorRefusedException) {
    // JanitorAI's own sentence, plus what it means for these books.
    return LabeledError(
      CatalogErrorSource.janitor,
      '${error.message}.\n${'catalog_janitor_refused_body'.tr()}',
    );
  }
  if (error is JanitorCfException) {
    return LabeledError(
      CatalogErrorSource.janitor,
      'catalog_error_janitor_cloudflare'.tr(),
    );
  }
  if (error is NoActiveConnectionException) {
    return LabeledError(
      CatalogErrorSource.glaze,
      'catalog_lorebooks_no_connection'.tr(),
    );
  }
  if (error is LorebookBuildException) {
    return LabeledError(error.source, error.message);
  }
  // Anything else — a provider `DioException` above all — goes through the
  // same formatter the chat uses for a failed generation.
  return LabeledError(fallback, formatError(error));
}
