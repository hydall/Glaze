import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../shared/shell/desktop/desktop_layout_provider.dart';

/// The orientations the app allows outside screens that unlock rotation.
///
/// Phones are locked to portrait; tablets may rotate, and it is the landscape
/// width that then turns on the desktop layout. This may run before any widget
/// exists, so it reads the first view's physical size and divides by its
/// density to tell the two apart. An unreadable size keeps the phone lock.
List<DeviceOrientation> appDefaultOrientations() {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isNotEmpty) {
    final view = views.first;
    final dpr = view.devicePixelRatio;
    if (dpr > 0) {
      final logical = view.physicalSize / dpr;
      if (logical.shortestSide >= kTabletShortestSideBreakpoint) {
        return DeviceOrientation.values;
      }
    }
  }
  return const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown];
}
