import 'package:easy_localization/easy_localization.dart';

/// Who produced a failure in the JanitorAI capture/build flow.
///
/// The flow talks to two very different remote parties in sequence — Janitor.AI
/// (the capture) and the user's own LLM provider (the rebuild) — and the fix is
/// different for each: log in again vs. check the API connection. Naming the
/// party in the error header is what tells them apart.
enum CatalogErrorSource {
  /// janitorai.com itself: an expired session, a refusal, Cloudflare.
  janitor,

  /// The user's active LLM connection — anything the transport reported.
  provider,

  /// Glaze's own side: nothing configured, nothing usable to work with.
  glaze,
}

extension CatalogErrorSourceLabel on CatalogErrorSource {
  /// Header for `GlazeErrorBlock`, in the chat error window's shouting style.
  String get label => switch (this) {
    CatalogErrorSource.janitor => 'error_source_janitor'.tr(),
    CatalogErrorSource.provider => 'error_source_provider'.tr(),
    CatalogErrorSource.glaze => 'error_source_generic'.tr(),
  };
}
