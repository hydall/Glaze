import 'package:easy_localization/easy_localization.dart';

import '../../core/llm/tokenizers/tokenizer_kind.dart';

/// Display name of [kind]. Tokenizer families are product names and stay as
/// they are; only the character estimate is a phrase to translate.
String tokenizerLabel(TokenizerKind kind) =>
    kind == TokenizerKind.approx ? 'tokenizer_approx'.tr() : kind.label;

/// The picker's hint line for [kind]: which models it belongs to.
String tokenizerModelsHint(TokenizerKind kind) =>
    kind == TokenizerKind.approx ? 'tokenizer_approx_hint'.tr() : kind.models;
