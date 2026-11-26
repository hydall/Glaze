import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/image_prompt_builder.dart';
import 'package:glaze_flutter/features/image_gen/widgets/reference_library_section.dart';

/// NovelAI reads the prompt as tags and takes its references natively, so the
/// prose Glaze writes about references for chat-style image models must not
/// reach it: it drew "Character reference descriptions: …" into a corner of
/// the image.
const _refs = [
  {'source': 'char', 'name': 'Hope', 'description': 'Hope'},
  {'source': 'additional', 'name': 'Zoe', 'description': 'red-haired mage'},
];

void main() {
  group('reference text in the prompt', () {
    test('a chat-style model gets the captions and the instruction', () {
      const settings = ImageGenSettings(apiType: ImageGenApiType.gemini);
      final prompt = withReferenceInstruction(
        buildFinalGenerationPrompt(
          prompt: 'two people talk',
          tagStyle: null,
          settings: settings,
          references: _refs,
        ),
        settings,
        hasReferences: true,
      );

      expect(prompt, contains('Character reference descriptions'));
      expect(prompt, contains('Reference descriptions'));
      expect(prompt, startsWith('[CRITICAL'));
    });

    test('NovelAI gets the prompt alone', () {
      const settings = ImageGenSettings(apiType: ImageGenApiType.novelai);
      final prompt = withReferenceInstruction(
        buildFinalGenerationPrompt(
          prompt: 'two people talk',
          tagStyle: null,
          settings: settings,
          references: _refs,
          wrapStyle: false,
        ),
        settings,
        hasReferences: true,
      );

      expect(prompt, 'two people talk');
    });

    test('appearance text goes as bare lines when asked', () {
      final block = buildCharacterDescriptionPromptBlock(
        mode: CharacterDescriptionsMode.asIs,
        references: const [],
        charDescription: 'red hair, green eyes',
        userDescription: 'tall, glasses',
        plain: true,
      );
      expect(block, 'red hair, green eyes\ntall, glasses');

      final labelled = buildCharacterDescriptionPromptBlock(
        mode: CharacterDescriptionsMode.asIs,
        references: const [],
        charDescription: 'red hair, green eyes',
      );
      expect(labelled, startsWith('Character descriptions:'));
    });
  });

  group('References group', () {
    Future<void> pump(
      WidgetTester tester,
      ImageGenSettings settings, {
      int maxReferences = 4,
      ValueChanged<ImageGenSettings>? onUpdate,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => SingleChildScrollView(
                  child: Column(
                    children: buildReferencesGroup(
                      context: context,
                      settings: settings,
                      maxReferences: maxReferences,
                      onUpdate: onUpdate ?? (_) {},
                      pickImage: () async => null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('splits pictures from prompt text', (tester) async {
      await pump(
        tester,
        const ImageGenSettings(apiType: ImageGenApiType.gemini),
      );

      expect(find.text('imggen_refs_pictures'), findsOneWidget);
      expect(find.text('imggen_refs_text'), findsOneWidget);
      expect(find.text('imggen_send_ref_descriptions'), findsOneWidget);
      expect(find.text('imggen_ref_instruction'), findsOneWidget);
      expect(find.text('imggen_refs_text_novelai'), findsNothing);
    });

    testWidgets('NovelAI explains instead of offering text switches', (
      tester,
    ) async {
      await pump(
        tester,
        const ImageGenSettings(apiType: ImageGenApiType.novelai),
      );

      expect(find.text('imggen_refs_text_novelai'), findsOneWidget);
      expect(find.text('imggen_send_ref_descriptions'), findsNothing);
      expect(find.text('imggen_ref_instruction'), findsNothing);
      expect(find.text('imggen_nai_ref_title'), findsOneWidget);
    });

    testWidgets('a model without pictures offers the character as text only', (
      tester,
    ) async {
      await pump(
        tester,
        const ImageGenSettings(apiType: ImageGenApiType.a1111),
        maxReferences: 0,
      );

      expect(find.text('imggen_refs_desc_text_only'), findsOneWidget);
      expect(find.text('imggen_refs_pictures'), findsNothing);
      await tester.tap(find.text('imggen_char_mode'));
      await tester.pumpAndSettle();
      expect(find.text('imggen_char_mode_text'), findsOneWidget);
      expect(find.text('imggen_char_mode_image'), findsNothing);
    });

    testWidgets('the character picker turns the avatar off', (tester) async {
      ImageGenSettings? updated;
      await pump(
        tester,
        const ImageGenSettings(
          apiType: ImageGenApiType.gemini,
          sendCharAvatar: true,
        ),
        onUpdate: (s) => updated = s,
      );

      expect(find.text('imggen_char_mode_image'), findsOneWidget);
      await tester.tap(find.text('imggen_char_mode'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('imggen_char_mode_off').last);
      await tester.pumpAndSettle();

      expect(updated?.sendCharAvatar, isFalse);
    });
  });
}
