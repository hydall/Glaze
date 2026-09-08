import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/widgets/model_fields.dart';

void main() {
  test('Seedream hides the ignored quality selector', () {
    final seedream = buildRoutmyModelFields(
      const ImageGenSettings(routmyModel: 'bytedance/seedream-5.0-pro'),
      isRu: false,
      onUpdate: (_) {},
      showOptions:
          <T>({
            required title,
            required items,
            required labelBuilder,
            required isSelected,
            required onSelected,
          }) {},
    );
    final generic = buildRoutmyModelFields(
      const ImageGenSettings(routmyModel: 'meta/muse-spark-1.1'),
      isRu: false,
      onUpdate: (_) {},
      showOptions:
          <T>({
            required title,
            required items,
            required labelBuilder,
            required isSelected,
            required onSelected,
          }) {},
    );

    expect(seedream, hasLength(3));
    expect(generic, hasLength(4));
  });
}
