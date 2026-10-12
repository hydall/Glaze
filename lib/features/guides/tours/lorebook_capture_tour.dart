import '../guide_anchor.dart';
import '../guide_tour.dart';

/// The JanitorAI lorebook capture sheet, run once when it first opens.
///
/// The opening step introduces the sheet; the rest point at the three parts of
/// the flow in order — what downloads whole, what is sent into the JanitorAI
/// chat to make the closed entries fire, and the action that runs the capture.
/// Every step past the intro is optional: a character with no public books, or
/// none closed, drops the steps that do not apply, and a solo intro still runs.
List<GuideTourStep> lorebookCaptureTourSteps() => [
  GuideTourStep.tr('guide_lorebook_capture'),
  GuideTourStep.tr(
    'guide_lorebook_public',
    target: GuideIds.lorebookCapturePublic,
    optional: true,
  ),
  GuideTourStep.tr(
    'guide_lorebook_extract',
    target: GuideIds.lorebookCaptureExtract,
    optional: true,
  ),
  GuideTourStep.tr(
    'guide_lorebook_collect',
    target: GuideIds.lorebookCaptureCollect,
    optional: true,
  ),
];
