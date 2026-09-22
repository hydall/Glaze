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

/// How a block's finished content reaches the reader.
///
/// This is what used to be the difference between the `infoblock` and
/// `interactive` block types. Nothing about *producing* the content changed
/// between them — only where it was put — so it is a property of the result,
/// not a kind of block.
enum BlockRender {
  /// Sanitized HTML (or plain text) in the message's ext-blocks panel.
  @JsonValue('card')
  card,

  /// A sandboxed `allow-scripts` iframe under the message, hosted by
  /// `PanelHostService`. The HTML stays executable there, so this is the one
  /// place a block's own JavaScript runs without going through the bridge.
  @JsonValue('panel')
  panel,
}
