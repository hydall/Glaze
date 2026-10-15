import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/character.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/models/persona.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../shared/widgets/glaze_toast.dart';
import '../../../chat/chat_message_service.dart';
import '../../../chat/chat_provider.dart';
import '../../models/block_config.dart';
import '../../models/block_modes.dart';
import '../../models/extension_preset.dart';
import '../blocks/block_prompt_regex.dart';
import '../blocks/block_tag_utils.dart';
import '../info_block_service.dart';
import 'search_replace_diff.dart';

final extBlocksRewriteServiceProvider = Provider<ExtBlocksRewriteService>(
  (ref) => ExtBlocksRewriteService(ref),
);

/// What one rewrite block produced.
class RewriteOutcome {
  const RewriteOutcome({
    required this.text,
    required this.mode,
    this.hunksApplied = 0,
    this.noChanges = false,
  });

  /// The new text for the rewrite target.
  final String text;
  final RewriteMode mode;
  final int hunksApplied;

  /// The model decided the target needs no change.
  final bool noChanges;
}

/// The part of a message a rewrite replaces: all of it, or [start]..[end].
class RewriteTarget {
  RewriteTarget._(this.text, this.start, this.end, {required this.isRange});

  String text;
  final int start;
  int end;
  final bool isRange;

  /// Resolves the target the way the original's `_getRewriteTarget` does.
  ///
  /// Without [textToRewrite] the whole message is rewritten. With it, an
  /// exact [range] is used when it still matches; otherwise the text is
  /// looked up and must occur exactly once.
  factory RewriteTarget.resolve(
    String messageText, {
    String? textToRewrite,
    ({int start, int end})? range,
  }) {
    if (textToRewrite == null) {
      return RewriteTarget._(
        messageText,
        0,
        messageText.length,
        isRange: false,
      );
    }
    if (range != null &&
        range.start >= 0 &&
        range.end >= range.start &&
        range.end <= messageText.length) {
      if (messageText.substring(range.start, range.end) != textToRewrite) {
        throw StateError(
          'The selected rewrite range no longer matches the message text.',
        );
      }
      return RewriteTarget._(
        textToRewrite,
        range.start,
        range.end,
        isRange: true,
      );
    }
    if (textToRewrite == messageText) {
      return RewriteTarget._(
        messageText,
        0,
        messageText.length,
        isRange: false,
      );
    }
    if (textToRewrite.isEmpty) {
      throw StateError('The partial rewrite target is empty.');
    }
    final first = messageText.indexOf(textToRewrite);
    if (first == -1) {
      throw StateError(
        'The partial rewrite target was not found in the message.',
      );
    }
    if (messageText.indexOf(textToRewrite, first + 1) != -1) {
      throw StateError(
        'The partial rewrite target is ambiguous. Select it in the message '
        'editor to provide an exact range.',
      );
    }
    return RewriteTarget._(
      textToRewrite,
      first,
      first + textToRewrite.length,
      isRange: true,
    );
  }

  /// [messageText] with the target replaced by [replacement]; the target then
  /// covers the replacement, so the next block rewrites the new text.
  String apply(String messageText, String replacement) {
    final next = isRange
        ? messageText.substring(0, start) +
              replacement +
              messageText.substring(end)
        : replacement;
    text = replacement;
    end = start + replacement.length;
    return next;
  }
}

/// Runs rewrite blocks: the model rewrites a message (or part of it), whole
/// or as search/replace hunks, and the message's text is replaced.
///
/// Mirrors the original extension's `RewritePlugin`.
class ExtBlocksRewriteService {
  ExtBlocksRewriteService(this._ref);

  final Ref _ref;

  /// Asks the model for [block]'s rewrite of [sourceText].
  ///
  /// [applyRegex] puts the result through the prompt regex pass when the
  /// block asks for it; the public "just give me the text" path leaves it
  /// off, as the original does.
  Future<RewriteOutcome> generateRewrite({
    required BlockConfig block,
    required String sourceText,
    required String charId,
    required String sessionId,
    required String messageId,
    required int swipeId,
    required List<ChatMessage> messages,
    required Character? character,
    required Persona? persona,
    required ExtensionPreset? preset,
    Map<String, String> additionalMacros = const {},
    bool applyRegex = false,
    CancelToken? cancelToken,
  }) async {
    final searchReplace = block.rewriteMode == RewriteMode.searchReplace;
    final promptBlock = searchReplace
        ? block.copyWith(
            template: '',
            prompt: [
              block.prompt.trim(),
              searchReplaceDiffOutputTemplate,
            ].where((p) => p.isNotEmpty).join('\n\n'),
          )
        : block;

    final generated = await _ref
        .read(infoBlockServiceProvider)
        .generateSingleBlockContent(
          sessionId: sessionId,
          messageId: messageId,
          messages: messages,
          blockConfig: promptBlock,
          character: character,
          persona: persona?.name,
          personaModel: persona,
          previousOutput: null,
          contextPolicy: block.contextPolicy,
          preset: preset,
          swipeId: swipeId,
          cancelToken: cancelToken,
          dynamicMacros: {...additionalMacros, 'textToRewrite': sourceText},
          leadingSystemPrompt: searchReplace ? searchReplaceDiffProtocol : null,
          returnRawResponse: true,
        );
    if (cancelToken?.isCancelled == true) {
      throw StateError('The rewrite was cancelled.');
    }
    final response = generated.content;
    if (generated.error != null ||
        response == null ||
        response.isEmpty ||
        response.contains('Proxy error')) {
      throw StateError(
        generated.error ??
            'The API returned an empty or invalid rewrite response.',
      );
    }

    Future<String> regexed(String text) => applyRegex && block.applyRegex
        ? applyExtBlockPromptRegexes(
            _ref,
            charId: charId,
            character: character,
            persona: persona,
            content: text,
          )
        : Future.value(text);

    if (searchReplace) {
      if (isSearchReplaceNoChanges(response)) {
        return RewriteOutcome(
          text: sourceText,
          mode: RewriteMode.searchReplace,
          noChanges: true,
        );
      }
      final hunks = <SearchReplaceHunk>[];
      for (final hunk in parseSearchReplaceDiff(response)) {
        hunks.add(hunk.copyWith(replace: await regexed(hunk.replace)));
      }
      final applied = applySearchReplaceDiff(sourceText, hunks);
      return RewriteOutcome(
        text: applied.text,
        mode: RewriteMode.searchReplace,
        hunksApplied: applied.appliedCount,
      );
    }

    var rewritten = multiBlockContentFromMessage(response, 'rewritten text');
    rewritten = await regexed(rewritten);
    if (rewritten.isEmpty) {
      throw StateError(
        'No <rewritten text> content was found in the model response.',
      );
    }
    return RewriteOutcome(text: rewritten, mode: RewriteMode.full);
  }

  /// Rewrites [messageId] with [blocks] in turn, each one working on what the
  /// previous left, and saves the message once at the end.
  ///
  /// [textToRewrite] and [range] narrow the rewrite to part of the message,
  /// as the original's partial rewrite does. Returns the chat's messages with
  /// the new text in place (unchanged when every block failed or changed
  /// nothing), so a chain can carry on with what the reader now sees.
  Future<List<ChatMessage>> rewriteMessage({
    required List<BlockConfig> blocks,
    required String charId,
    required String sessionId,
    required String messageId,
    required List<ChatMessage> messages,
    required Character? character,
    required Persona? persona,
    required ExtensionPreset? preset,
    Map<String, String> additionalMacros = const {},
    String? textToRewrite,
    ({int start, int end})? range,
    CancelToken? cancelToken,
  }) async {
    if (blocks.isEmpty) return messages;
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0) {
      _toast('extblocks_rewrite_no_target'.tr(), isError: true);
      return messages;
    }
    final message = messages[index];

    final RewriteTarget target;
    try {
      target = RewriteTarget.resolve(
        message.content,
        textToRewrite: textToRewrite,
        range: range,
      );
    } on StateError catch (e) {
      _toast(e.message, isError: true);
      return messages;
    }

    _toast('extblocks_rewrite_started'.tr());
    var text = message.content;
    var succeeded = 0;
    var failed = 0;
    for (final block in blocks) {
      if (cancelToken?.isCancelled == true) break;
      try {
        final outcome = await generateRewrite(
          block: block,
          sourceText: target.text,
          charId: charId,
          sessionId: sessionId,
          messageId: messageId,
          swipeId: message.swipeId,
          messages: [
            ...messages.take(index),
            message.copyWith(content: text),
            ...messages.skip(index + 1),
          ],
          character: character,
          persona: persona,
          preset: preset,
          additionalMacros: additionalMacros,
          applyRegex: true,
          cancelToken: cancelToken,
        );
        text = target.apply(text, outcome.text);
        succeeded++;
      } catch (e) {
        if (cancelToken?.isCancelled == true) break;
        failed++;
        debugPrint('[ExtBlocks] rewrite block "${block.name}" failed: $e');
        _toast(
          'extblocks_rewrite_block_failed'.tr(args: [block.name, '$e']),
          isWarning: true,
        );
      }
    }

    if (succeeded == 0) {
      if (failed > 0) _toast('extblocks_rewrite_failed'.tr(), isError: true);
      return messages;
    }
    if (text != message.content) {
      await _save(charId, sessionId, messageId, text);
    }
    _toast(
      failed == 0
          ? 'extblocks_rewrite_done'.tr()
          : 'extblocks_rewrite_partial'.tr(),
      isWarning: failed > 0,
    );
    return [
      ...messages.take(index),
      message.copyWith(
        content: text,
        swipes: [
          for (var i = 0; i < message.swipes.length; i++)
            i == message.swipeId ? text : message.swipes[i],
        ],
      ),
      ...messages.skip(index + 1),
    ];
  }

  /// Saves through the open chat when it is this one, so the reader sees the
  /// change at once; otherwise straight to the stored session.
  Future<void> _save(
    String charId,
    String sessionId,
    String messageId,
    String text,
  ) async {
    final open = _ref.read(chatProvider(charId)).value?.session;
    if (open?.id == sessionId) {
      final saved = await _ref
          .read(chatProvider(charId).notifier)
          .replaceMessageText(messageId, text);
      if (saved != null) return;
    }
    final stored = await _ref.read(chatRepoProvider).getById(sessionId);
    if (stored == null) return;
    final index = stored.messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    final service = ChatMessageService(_ref);
    await service.commitMessageMutation(
      stored,
      index,
      (latest, latestIndex) => service.editMessage(latest, latestIndex, text),
    );
  }

  void _toast(String text, {bool isError = false, bool isWarning = false}) {
    try {
      GlazeToast.showWithoutContext(
        text,
        isError: isError,
        isWarning: isWarning,
      );
    } catch (e) {
      debugPrint('[ExtBlocks] $text');
    }
  }
}
