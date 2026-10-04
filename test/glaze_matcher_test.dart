import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/glaze_matcher.dart';

void main() {
  test('tavern matcher keeps regular expression compatibility', () {
    expect(
      glazeCheckMatch(r'cat|dog', 'a dog appears', false, WholeWordMode.no),
      isTrue,
    );
  });

  test('pathological regular expression falls back to literal matching', () {
    const unsafeKey = r'(a+)+$';

    expect(
      glazeCheckMatch(
        unsafeKey,
        'the literal key is (a+)+\$',
        false,
        WholeWordMode.no,
      ),
      isTrue,
    );
    expect(
      glazeCheckMatch(
        unsafeKey,
        '${List.filled(20000, 'a').join()}!',
        false,
        WholeWordMode.no,
      ),
      isFalse,
    );
  });
}
