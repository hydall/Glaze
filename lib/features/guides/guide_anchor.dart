import 'package:flutter/widgets.dart';

/// Marks [child] as something a guide tour can point at, under [id].
///
/// Deliberately not a [GlobalKey]: the same control can be mounted twice at
/// once (a shell branch kept alive offstage, a desktop sidebar beside its tab),
/// and two widgets sharing a global key is a crash. Anchors register here
/// instead, and the tour asks [GuideAnchors] for the one actually on screen.
///
/// A null [id] makes the anchor a pass-through, so a list can wrap every row
/// the same way and name only the one the tour wants.
class GuideAnchor extends StatefulWidget {
  final String? id;
  final Widget child;

  const GuideAnchor({super.key, required this.id, required this.child});

  @override
  State<GuideAnchor> createState() => _GuideAnchorState();
}

class _GuideAnchorState extends State<GuideAnchor> {
  @override
  void initState() {
    super.initState();
    GuideAnchors._register(widget.id, this);
  }

  @override
  void didUpdateWidget(covariant GuideAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      GuideAnchors._unregister(oldWidget.id, this);
      GuideAnchors._register(widget.id, this);
    }
  }

  @override
  void dispose() {
    GuideAnchors._unregister(widget.id, this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Lookup of the mounted [GuideAnchor]s.
abstract final class GuideAnchors {
  static final Map<String, List<_GuideAnchorState>> _byId = {};

  static void _register(String? id, _GuideAnchorState state) {
    if (id == null) return;
    (_byId[id] ??= []).add(state);
  }

  static void _unregister(String? id, _GuideAnchorState state) {
    if (id == null) return;
    final list = _byId[id];
    list?.remove(state);
    if (list != null && list.isEmpty) _byId.remove(id);
  }

  /// The context of the anchor named [id] that is on screen right now — the
  /// most recently mounted one when several are. Null when none is: never
  /// mounted, laid out at zero size, or in a part of the tree that is
  /// offstage (an inactive shell branch, a route covered by another).
  static BuildContext? contextOf(String id) {
    final list = _byId[id];
    if (list == null) return null;
    for (final state in list.reversed) {
      if (!state.mounted) continue;
      final context = state.context;
      if (!TickerMode.valuesOf(context).enabled) continue;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      if (box.size.isEmpty) continue;
      return context;
    }
    return null;
  }

  /// Where the anchor named [id] sits, in global coordinates.
  static Rect? rectOf(String id) {
    final box = contextOf(id)?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  static bool isVisible(String id) => contextOf(id) != null;
}

/// The ids the tours point at, in one place so a screen and its tour cannot
/// drift apart over a typo.
abstract final class GuideIds {
  static const navBar = 'nav.bar';
  static String navTab(int index) => 'nav.tab.$index';

  static const chatsSearch = 'chats.search';

  static const chatHeader = 'chat.header';
  static const chatSearch = 'chat.search';
  static const chatComposer = 'chat.composer';
  static const chatSend = 'chat.send';

  /// A button in the row under the composer, by its encoded [ComposerPin].
  static String chatPin(String encodedPin) => 'chat.pin.$encodedPin';

  static const charsTabs = 'chars.tabs';
  static const charsSearch = 'chars.search';
  static const charsAdd = 'chars.add';
  static const charsFolders = 'chars.folders';
  static const charsRandom = 'chars.random';
  static const charsFilter = 'chars.filter';
  static const charsCard = 'chars.card';

  static String toolsTile(String tileId) => 'tools.tile.$tileId';
  static const toolsEdit = 'tools.edit';

  static const apiAdd = 'api.add';
  static const apiSwitcher = 'api.switcher';
  static const apiTabs = 'api.tabs';
  static const apiConnection = 'api.connection';

  static const presetsRow = 'presets.row';
  static const presetsControls = 'presets.controls';
  static const presetsAdd = 'presets.add';

  static const personasAdd = 'personas.add';
  static const personasFolder = 'personas.folder';
  static const personasRow = 'personas.row';

  static const moreSettings = 'more.settings';
  static const moreSearch = 'more.search';
  static const moreData = 'more.data';
  static const moreHelp = 'more.help';
}
