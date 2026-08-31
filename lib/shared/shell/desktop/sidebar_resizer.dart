import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _collapseThreshold = 120.0;
const _collapsedWidth = 64.0;

/// Width a sidebar snaps to when collapsed, and the width below which it counts
/// as collapsed. Public so the shell can shrink a sidebar to its icon strip
/// when the window is too narrow to afford the stored width.
const double kSidebarCollapsedWidth = _collapsedWidth;
const double kSidebarCollapseThreshold = _collapseThreshold;

double? _readDoublePref(SharedPreferences? prefs, String key) {
  final value = prefs?.get(key);
  if (value is int) return value.toDouble();
  if (value is double) return value;
  if (value is String) return double.tryParse(value);
  return null;
}

bool _readBoolPref(
  SharedPreferences? prefs,
  String key, {
  required bool defaultValue,
}) {
  if (prefs == null) return defaultValue;
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
  LeftSidebarController({required double initialWidth}) : _width = initialWidth;

  double _width;

  static const defaultWidth = 280.0;
  static const minWidth = 200.0;
  static const maxWidth = 600.0;

  double get width => _width;
  bool get collapsed => _width < _collapseThreshold;

  /// True while the grip is being dragged. The sidebar surface animates its
  /// width on collapse/expand, but must follow the pointer 1:1 during a drag —
  /// otherwise the edge lags behind the cursor by the animation duration.
  bool _dragging = false;
  bool get dragging => _dragging;

  void beginDrag() {
    if (_dragging) return;
    _dragging = true;
    notifyListeners();
  }

  void endDrag() {
    if (!_dragging) return;
    _dragging = false;
    notifyListeners();
  }

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

  static double _storedWidth(SharedPreferences? prefs) {
    final collapsedFlag = _readBoolPref(
      prefs,
      'gz_left_sidebar_width_collapsed',
      defaultValue: false,
    );
    if (collapsedFlag) return _collapsedWidth;
    final saved = _readDoublePref(prefs, 'gz_left_sidebar_width');
    if (saved == null) return defaultWidth;
    return saved.clamp(minWidth, maxWidth);
  }

  /// [prefs] may be null when they have not resolved yet — the controller then
  /// starts from the defaults and adopts the stored width via [applyPrefs].
  static LeftSidebarController fromPrefs(SharedPreferences? prefs) =>
      LeftSidebarController(initialWidth: _storedWidth(prefs));

  void applyPrefs(SharedPreferences prefs) {
    final stored = _storedWidth(prefs);
    if ((stored - _width).abs() < 0.5) return;
    _width = stored;
    notifyListeners();
  }

  /// Collapse / expand without dragging (double-click on the drag handle).
  void toggleCollapse(SharedPreferences prefs) {
    _width = collapsed ? defaultWidth : _collapsedWidth;
    _persist(prefs);
    notifyListeners();
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

  /// True while the grip is being dragged. The sidebar surface animates its
  /// width on collapse/expand, but must follow the pointer 1:1 during a drag —
  /// otherwise the edge lags behind the cursor by the animation duration.
  bool _dragging = false;
  bool get dragging => _dragging;

  void beginDrag() {
    if (_dragging) return;
    _dragging = true;
    notifyListeners();
  }

  void endDrag() {
    if (!_dragging) return;
    _dragging = false;
    notifyListeners();
  }

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

  /// [prefs] may be null when they have not resolved yet — see
  /// [LeftSidebarController.fromPrefs].
  static RightSidebarController fromPrefs(SharedPreferences? prefs) {
    // Expanded by default, matching the Vue app: a collapsed right sidebar in
    // chat shows only the icon strip, which is a poor first impression of the
    // desktop layout.
    final collapsedFlag = _readBoolPref(
      prefs,
      'gz_right_sidebar_width_collapsed',
      defaultValue: false,
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

  void applyPrefs(SharedPreferences prefs) {
    final fresh = fromPrefs(prefs);
    _expandedWidth = fresh._expandedWidth;
    _collapsedWidth = fresh._collapsedWidth;
    _collapsed = fresh._collapsed;
    notifyListeners();
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

  void toggleCollapse(SharedPreferences prefs) {
    _wasAutoExpanded = false;
    _collapsed = !_collapsed;
    finishResize(prefs);
  }
}

final rightSidebarControllerProvider =
    Provider.autoDispose<RightSidebarController>((ref) {
      throw UnimplementedError(
        'Must be overridden by a parent that creates the controller',
      );
    });
