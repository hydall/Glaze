import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_image_stripper.dart';

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
}
