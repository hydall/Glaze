import '../guide_anchor.dart';
import '../guide_tour.dart';

/// The Tools tab: one step per tile, in the default order, then the pencil
/// that rearranges them. A tile the reader hid drops out of the tour.
///
/// API, Presets and Personas only say what they are and where else they open;
/// each screen walks through its own setup the first time it opens.
List<GuideTourStep> toolsTourSteps() => [
  for (final (tile, key) in const [
    ('api', 'guide_tools_api'),
    ('presets', 'guide_tools_presets'),
    ('personas', 'guide_tools_personas'),
    ('lorebooks', 'guide_tools_lorebooks'),
    ('regex', 'guide_tools_regex'),
    ('ext-blocks', 'guide_tools_ext_blocks'),
    ('image-gen', 'guide_tools_imggen'),
    ('stats', 'guide_tools_stats'),
  ])
    GuideTourStep.tr(key, target: GuideIds.toolsTile(tile), optional: true),
  GuideTourStep.tr('guide_tools_edit', target: GuideIds.toolsEdit),
];
