import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/shell/desktop/sidebar_resizer.dart';

void main() {
  test('left sidebar accepts legacy string prefs', () async {
    SharedPreferences.setMockInitialValues({
      'gz_left_sidebar_width': '320',
      'gz_left_sidebar_width_collapsed': '0',
    });

    final prefs = await SharedPreferences.getInstance();
    final controller = LeftSidebarController.fromPrefs(prefs);

    expect(controller.width, 320);
    expect(controller.collapsed, isFalse);
  });

  test('right sidebar accepts legacy string prefs', () async {
    SharedPreferences.setMockInitialValues({
      'gz_right_sidebar_width': '420.5',
      'gz_right_sidebar_collapsed_width': '72',
      'gz_right_sidebar_width_collapsed': 'false',
    });

    final prefs = await SharedPreferences.getInstance();
    final controller = RightSidebarController.fromPrefs(prefs);

    expect(controller.width, 420.5);
    expect(controller.collapsed, isFalse);
  });
}
