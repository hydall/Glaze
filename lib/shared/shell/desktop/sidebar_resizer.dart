import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _collapseThreshold = 120.0;
const _collapsedWidth = 64.0;

double? _readDoublePref(SharedPreferences prefs, String key) {
  final value = prefs.get(key);
  if (value is int) return value.toDouble();
  if (value is double) return value;
  if (value is String) return double.tryParse(value);
  return null;
}

bool _readBoolPref(
  SharedPreferences prefs,
  String key, {
  required bool defaultValue,
}) {
  final value = prefs.get(key);
  if (value is bool) return value;
  if (value is int) return value != 0;
  if (value is String) {
    final normalized = value.toLowerCase();
    return normalized == '1' || normalized == 'true';
  }
  return defaultValue;
}

// ---------------------------------------------------------------------------
// Left sidebar controller
// ---------------------------------------------------------------------------

class LeftSidebarController extends ChangeNotifier {
  LeftSidebarController({
    required double initialWidth,
    required bool initialCollapsed,
  }) : _width = initialWidth;

  double _width;

  static const defaultWidth = 280.0;
  static const minWidth = 200.0;
  static const maxWidth = 600.0;

  double get width => _width;
  bool get collapsed => _width < _collapseThreshold;

  set width(double value) {
    final clamped = value.clamp(_collapsedWidth, maxWidth);
    if ((clamped - _width).abs() < 0.5) return;
    _width = clamped;
    notifyListeners();
  }

  void finishResize(SharedPreferences prefs) {
    if (collapsed) {
      _width = _collapsedWidth;
    } else if (_width < minWidth) {
      _width = minWidth;
    }
    _persist(prefs);
    notifyListeners();
  }

  void _persist(SharedPreferences prefs) {
    prefs.setInt('gz_left_sidebar_width', _width.round());
    prefs.setString('gz_left_sidebar_width_collapsed', collapsed ? '1' : '0');
  }

  static LeftSidebarController fromPrefs(SharedPreferences prefs) {
    final collapsedFlag = _readBoolPref(
      prefs,
      'gz_left_sidebar_width_collapsed',
      defaultValue: false,
    );
    final saved = _readDoublePref(prefs, 'gz_left_sidebar_width');
    double initial;
    if (collapsedFlag) {
      initial = _collapsedWidth;
    } else if (saved != null) {
      initial = saved.clamp(minWidth, maxWidth);
    } else {
      initial = defaultWidth;
    }
    return LeftSidebarController(
      initialWidth: initial,
      initialCollapsed: collapsedFlag,
    );
  }
}

final leftSidebarControllerProvider =
    Provider.autoDispose<LeftSidebarController>((ref) {
      throw UnimplementedError(
        'Must be overridden by a parent that creates the controller',
      );
    });

// ---------------------------------------------------------------------------
// Right sidebar controller — 1:1 port of DesktopRightSidebar.vue resizer
// ---------------------------------------------------------------------------

class RightSidebarController extends ChangeNotifier {
  RightSidebarController({
    required double initialExpandedWidth,
    required double initialCollapsedWidth,
    required bool initialCollapsed,
  }) : _expandedWidth = initialExpandedWidth,
       _collapsedWidth = initialCollapsedWidth,
       _collapsed = initialCollapsed,
       _wasAutoExpanded = false;

  double _expandedWidth;
  double _collapsedWidth;
  bool _collapsed;
  bool _wasAutoExpanded;

  static const expandedDefault = 300.0;
  static const expandedMin = 200.0;
  static const expandedMax = 800.0;

  static const collapsedDefaultWidth = 64.0;
  static const collapsedMin = 48.0;

  double get width => _collapsed ? _collapsedWidth : _expandedWidth;
  bool get collapsed => _collapsed;

  // ── Port of Vue DesktopRightSidebar.vue startRightResize onMouseMove ──
  // Drag handle passes raw newWidth; this method handles mode switching at
  // COLLAPSE_THRESHOLD (120px), keeping expanded/collapsed widths independent.
  void handleDragUpdate(double newWidth, bool startingCollapsed) {
    if (startingCollapsed) {
      if (newWidth >= _collapseThreshold) {
        _collapsed = false;
        _expandedWidth = newWidth.clamp(0.0, expandedMax);
      } else {
        _collapsed = true;
        _collapsedWidth = newWidth.clamp(collapsedMin, double.infinity);
      }
    } else {
      if (newWidth < _collapseThreshold) {
        _collapsed = true;
      } else {
        _collapsed = false;
        _expandedWidth = newWidth.clamp(0.0, expandedMax);
      }
    }
    notifyListeners();
  }

  // ── Port of Vue DesktopRightSidebar.vue startRightResize onMouseUp ──
  void finishResize(SharedPreferences prefs) {
    if (_collapsed) {
      _collapsedWidth = _collapsedWidth.clamp(
        collapsedMin,
        _collapseThreshold - 1,
      );
      prefs.setDouble('gz_right_sidebar_collapsed_width', _collapsedWidth);
      prefs.setString('gz_right_sidebar_width_collapsed', '1');
    } else {
      _expandedWidth = _expandedWidth.clamp(expandedMin, expandedMax);
      prefs.setDouble('gz_right_sidebar_width', _expandedWidth);
      prefs.setString('gz_right_sidebar_width_collapsed', '0');
    }
    notifyListeners();
  }

  static RightSidebarController fromPrefs(SharedPreferences prefs) {
    final collapsedFlag = _readBoolPref(
      prefs,
      'gz_right_sidebar_width_collapsed',
      defaultValue: true,
    );
    final savedExpanded = _readDoublePref(prefs, 'gz_right_sidebar_width');
    final savedCollapsed = _readDoublePref(
      prefs,
      'gz_right_sidebar_collapsed_width',
    );
    return RightSidebarController(
      initialExpandedWidth: (savedExpanded ?? expandedDefault).clamp(
        expandedMin,
        expandedMax,
      ),
      initialCollapsedWidth: (savedCollapsed ?? collapsedDefaultWidth).clamp(
        collapsedMin,
        expandedMin,
      ),
      initialCollapsed: collapsedFlag,
    );
  }

  // -----------------------------------------------------------------------
  // Auto-expand / restore for sheets
  // -----------------------------------------------------------------------

  bool get wasAutoExpanded => _wasAutoExpanded;

  void autoExpand() {
    if (_collapsed) {
      _wasAutoExpanded = true;
      _collapsed = false;
      notifyListeners();
    }
  }

  void restoreCollapse() {
    if (_wasAutoExpanded) {
      _wasAutoExpanded = false;
      _collapsed = true;
      notifyListeners();
    }
  }

  void toggleCollapse() {
    _wasAutoExpanded = false;
    _collapsed = !_collapsed;
    notifyListeners();
  }
}

final rightSidebarControllerProvider =
    Provider.autoDispose<RightSidebarController>((ref) {
      throw UnimplementedError(
        'Must be overridden by a parent that creates the controller',
      );
    });
