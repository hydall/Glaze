import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_image_stripper.dart';
import 'package:glaze_flutter/features/image_gen/services/image_tag_markup.dart';

void main() {
  test('strips local images from green and nested swipe content', () {
    final result = stripImagesFromSession({
      'messages': [
        {
          'content': 'text [IMG:RESULT:C:/generated/current.png]',
          'swipes': ['text [IMG:RESULT:C:/generated/green.png]'],
          'agentSwipes': [
            {'content': 'text [IMG:RESULT:C:/generated/blue.png]'},
          ],
          'swipesMeta': [
            {
              'agentSwipes': [
                {'content': 'text [IMG:RESULT:C:/generated/stored.png]'},
              ],
            },
          ],
        },
      ],
    });

    expect(result.toString(), isNot(contains('C:/generated/')));
  });

  // INV-IG9: the stored form of a finished block carries a path into this
  // device's data root, so it must not survive an upload either.
  test('strips the stored <img data-iig-…> form of a finished block', () {
    const stored =
        '<img data-iig-instruction=\'{"prompt":"cat"}\' '
        "data-iig-variants='generated/a.jpg;;generated/b.jpg' "
        'data-iig-index=\'1\' src="generated/b.jpg">';
    expect(stripImageContent('text $stored tail'), 'text  tail');
  });

  test('keeps a block that is still waiting for its image', () {
    // Its instruction is what lets the pulling device generate the picture
    // itself, so the element survives the strip (its `[IMG:GEN]` placeholder
    // goes the way of every other pending tag).
    const pending =
        '<img data-iig-instruction=\'{"prompt":"cat"}\' src="[IMG:GEN]">';
    final stripped = stripImageContent('text $pending');
    expect(stripped, contains('data-iig-instruction'));
    expect(stripped, contains(r'{"prompt":"cat"}'));
    expect(ImageTagMarkup.pendingImageGenTagCount(stripped), 1);
  });
}
