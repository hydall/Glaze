import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/preset_defaults.dart';

/// The [open]..[close] group in [source] starting at or after [from].
({String text, int end}) _group(
  String source,
  int from, {
  String open = '{',
  String close = '}',
}) {
  final start = source.indexOf(open, from);
  expect(start, greaterThan(-1), reason: 'no $open after offset $from');
  var depth = 0;
  for (var i = start; i < source.length; i++) {
    if (source[i] == open) depth++;
    if (source[i] == close) {
      depth--;
      if (depth == 0) return (text: source.substring(start, i + 1), end: i + 1);
    }
  }
  fail('unbalanced $open after offset $from');
}

/// The braced body that follows [signature].
String _bodyAfter(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThan(-1), reason: 'missing $signature');
  return _group(source, start).text;
}

/// The `[...]` list that follows [signature] — a collection-if's children.
String _listAfter(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThan(-1), reason: 'missing $signature');
  return _group(source, start, open: '[', close: ']').text;
}

void main() {
  final editor = File(
    'lib/features/presets/preset_editor_screen.dart',
  ).readAsStringSync();
  final composer = File(
    'lib/features/chat/widgets/chat_input_bar.dart',
  ).readAsStringSync();

  // Both guided prompts are preset fields, not block content, and no screen
  // ever offered a field for either: the editor read them straight off the
  // preset on every save, which is the same thing as being uneditable. The
  // Vue editor showed them under the Guided Generation block all along, and
  // every string for it is already translated in both languages — only the
  // widget was missing.
  group('the Guided Generation block is editable', () {
    test('the block routes to its own editor', () {
      expect(editor, contains("expanded.id == 'guided_generation'"));
      expect(editor, contains('_GuidedGenerationBlockEditor('));
    });

    test('it offers both prompts and the explanatory line', () {
      final body = _bodyAfter(editor, 'class _GuidedGenerationBlockEditor');

      expect(body, contains("'guided_generation_block_hint'.tr()"));
      expect(body, contains("'label_guided_generation_prompt'.tr()"));
      expect(body, contains("'label_guided_impersonation_prompt'.tr()"));
      // The same role/insertion/depth the other blocks carry.
      expect(body, contains("key: 'role'"));
      expect(body, contains("key: 'insertionMode'"));
      expect(body, contains("key: 'depth'"));
    });

    test('the prompts are lifted out before the rest is read as a block', () {
      // `PresetBlock.fromJson` would drop them, and the preset would silently
      // keep its old text while the editor showed the new one.
      final body = _bodyAfter(editor, 'class _GuidedGenerationBlockEditor');

      expect(body, contains('..remove(_generationKey)'));
      expect(body, contains('..remove(_impersonationKey)'));
    });

    test('an edit survives the save, instead of being read off the preset', () {
      // Both save paths used `widget.preset?.guidedGenerationPrompt`, so
      // whatever the editor did was overwritten by the stored value.
      expect(editor, contains('guidedGenerationPrompt: _guidedGenerationPrompt'));
      expect(
        editor,
        contains('guidedImpersonationPrompt: _guidedImpersonationPrompt'),
      );
      expect(
        editor,
        isNot(contains('guidedGenerationPrompt: widget.preset?')),
      );
    });

    test('an empty field falls back to the shipped default, not to nothing', () {
      // A preset that never set one shows the wording the pipeline actually
      // uses, so the editor is not lying about what will be sent.
      expect(
        editor,
        contains('_guidedGenerationPrompt ?? kDefaultGuidedGenerationPrompt'),
      );
      expect(
        editor,
        contains(
          '_guidedImpersonationPrompt ?? kDefaultGuidedImpersonationPrompt',
        ),
      );
    });
  });

  // The Vue composer had two guidance modes, each with its own header and
  // placeholder. Glaze folds them into one field and decides by whether a
  // message is waiting — the send button has always switched between the send
  // glyph and a checkmark on exactly that — but the panel never said which,
  // so the reader could not tell what pressing it would do.
  group('the guidance panel says what it will do', () {
    test('the mode is named, both ways', () {
      expect(composer, contains("'guided_impersonation'.tr()"));
      expect(composer, contains("'guided_generation'.tr()"));
    });

    test('the placeholder follows the mode', () {
      expect(composer, contains("'impersonate_guidance_placeholder'.tr()"));
      expect(composer, contains("'guidance_placeholder'.tr()"));
    });

    test('the mode is the same question the send button asks', () {
      // If these ever disagree the header becomes a lie, which is worse than
      // no header at all.
      expect(
        composer,
        contains(
          'bool get _guidanceImpersonates => _controller.text.trim().isEmpty',
        ),
      );
    });

    test('guidance can be dismissed from the panel itself', () {
      // It was only dismissable from whichever button opened it — a composer
      // action that may be pinned anywhere, or the drawer.
      final body = _listAfter(composer, 'if (_guidanceMode) ...[');
      expect(body, contains('Icons.close_rounded'));
      expect(body, contains('_toggleGuidance'));
    });
  });

  group('the strings and defaults it relies on', () {
    test('every label exists in both languages', () {
      for (final path in [
        'assets/translations/en.json',
        'assets/translations/ru.json',
      ]) {
        final json = File(path).readAsStringSync();
        for (final key in [
          'block_guided_generation',
          'guided_generation_block_hint',
          'label_guided_generation_prompt',
          'label_guided_impersonation_prompt',
          'guided_generation',
          'guided_impersonation',
          'guidance_placeholder',
          'impersonate_guidance_placeholder',
        ]) {
          expect(json, contains('"$key"'), reason: '$key missing from $path');
        }
      }
    });

    test('the defaults carry the macro the hint promises', () {
      // The hint says `{{guidance}}` is the user's instruction; a default
      // without it would drop whatever they typed.
      expect(kDefaultGuidedGenerationPrompt, contains('{{guidance}}'));
      expect(kDefaultGuidedImpersonationPrompt, contains('{{guidance}}'));
    });

    test('the block itself is still mandatory and static', () {
      // The editor is reached through the block row, so the block has to be
      // there — and being static is what keeps it from being toggled off.
      final block = defaultPresetBlocks().firstWhere(
        (b) => b.id == 'guided_generation',
      );
      expect(block.isStatic, isTrue);
      expect(block.enabled, isTrue);
    });
  });
}
