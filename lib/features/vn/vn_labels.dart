import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';

import 'models/vn_document.dart';
import 'services/vn_generator_service.dart';

/// The name of [pass] as the player reads it.
String vnPassLabel(VnPass pass) => switch (pass) {
  VnPass.scenario => 'vn_pass_scenario'.tr(),
  VnPass.characters => 'vn_pass_characters'.tr(),
  VnPass.locations => 'vn_pass_locations'.tr(),
  VnPass.textures => 'vn_pass_textures'.tr(),
  VnPass.chapter => 'vn_pass_chapter'.tr(),
};

String vnErrorText(Object error) => switch (error) {
  VnGenerationException(failure: VnGenerationFailure.noApi) =>
    'vn_err_no_api'.tr(),
  VnGenerationException(failure: VnGenerationFailure.incompleteApi) =>
    'vn_err_incomplete_api'.tr(),
  VnGenerationException(failure: VnGenerationFailure.badReply) =>
    'vn_err_bad_reply'.tr(),
  _ => 'vn_err_failed'.tr(args: [error.toString()]),
};

/// Why drawing the cast failed, as the player reads it.
String vnArtErrorText(Object error) => 'vn_drawing_failed'.tr(
  args: [
    switch (error) {
      DioException(:final message?) => message,
      _ => '$error',
    },
  ],
);

/// The chat-list preview of a novel whose newest message is [content].
String vnPreviewText(String content) {
  final preview = vnPreviewOf(content);
  final pass = preview.pass;
  if (pass == null) return 'vn_preview_starting'.tr();
  if (pass != VnPass.chapter) {
    return 'vn_preview_setup'.tr(args: [vnPassLabel(pass)]);
  }
  final head = 'vn_preview_chapter'.tr(args: ['${preview.chapter}']);
  return preview.summary.isEmpty ? head : '$head · ${preview.summary}';
}
