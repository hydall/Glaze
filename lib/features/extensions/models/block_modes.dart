import 'package:freezed_annotation/freezed_annotation.dart';

/// How a rewrite block's reply is turned into the new message text.
enum RewriteMode {
  /// The reply carries the whole rewritten text inside the template's tags.
  @JsonValue('full')
  full,

  /// The reply carries only the fragments that change, as search/replace
  /// hunks. Safer on long messages, and cheaper, but the model has to quote
  /// the original exactly.
  @JsonValue('search_replace')
  searchReplace,
}

/// Which language a script block is written in.
enum ScriptType {
  /// The host app's own command language.
  @JsonValue('stscript')
  stScript,

  /// JavaScript, run in the sandbox.
  @JsonValue('js')
  js,
}

/// Whether a rewrite or script block runs before or after the ordinary
/// generated blocks of the same message.
enum BlockRunOrder {
  @JsonValue('before')
  before,
  @JsonValue('after')
  after,
}
