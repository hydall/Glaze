# UI Kit

Glaze has its own widget set in `lib/shared/widgets/`. **Build screens, sheets
and dialogs out of it — do not reach for the raw Material equivalent when a
Glaze widget already covers the case.**

This is a real rule, not a preference: the kit is what carries the app's look
(glass surfaces, the theme preset's `elementOpacity` / `elementBlur` /
`noiseOpacity`, the ripple, the header blur, the overscroll stretch). A screen
assembled from bare `Card` / `TabBar` / `OutlinedButton` renders in stock
Material grey no matter what theme preset is active, and it silently opts out
of things the kit already solved — battery-saver degradation, backdrop-blur
interaction with the Android overscroll stretch, safe-area and nav-bar insets,
haptics on tap.

Until this file existed the rule was unwritten, and it showed: the memory books
sheet shipped on `DefaultTabController` + `TabBar` + `OutlinedButton` +
`FilterChip` without breaking any documented convention. If you find yourself
styling a Material widget with `Colors.white.withValues(alpha: 0.05)` and
`BorderRadius.circular(12)` to make it "look Glaze", stop — that is a
`GlassSurface` or a `MenuGroup`.

## What to use instead of what

| Instead of | Use | Notes |
|---|---|---|
| `Scaffold` + `AppBar` | `GlazeScaffold` (`glaze_scaffold.dart`) | Floating glass header for screens **outside** the shell. Screens inside a shell branch pass `useShellHeader: true` + `headerBranchIndex` and publish into the shell's persistent header instead. |
| `showModalBottomSheet` with a hand-rolled body | `SheetView` (`sheet_view.dart`) or `GlazeBottomSheet.show` (`glaze_bottom_sheet.dart`) | See "Which sheet" below. |
| `TabBar` / `TabBarView` / `DefaultTabController` | `GlazeTabBar` + `SwipeTabSwitcher` + `TabSlideSwitcher` | The segmented control. `GlazeTabBar` handles tap, swipe-on-the-strip and scrolling past ~2.35 tabs; `SwipeTabSwitcher` adds body swipe; `TabSlideSwitcher` animates the body in the swipe's direction. `style:` picks the look — `pill` (default) for a strip *inside* a screen or sheet, `underline` for one that *heads* a surface, where a filled accent segment would outweigh the content below it (the chat drawer). |
| `Card` / `Container` with a translucent fill | `GlassSurface` (`glass_surface.dart`) | Reads the active theme preset. Give it `onTap` for a `GlowInkWell` ripple, or `enableRipple: true` for the hover glow without a tap handler. |
| `ListTile` groups, settings rows | `MenuGroup` + `MenuItem` / `MenuSwitchItem` / `MenuSelectorItem` / `MenuFieldItem` / `MenuRangeItem` / `MenuScriptItem` / `MenuSubHeader` / `MenuCollapsibleSection` (`menu_group.dart`) | The standard settings/form row set. `MenuGroup` already supplies the surface, the border and the 16 px horizontal margin. |
| `ElevatedButton` / `OutlinedButton` / `FilledButton` in a toolbar | `GlassSurface` tile with `onTap`, or `GlazePillButton` (`glaze_scaffold.dart`) | There is no generic Glaze button — a tile built on `GlassSurface` *is* the button. |
| `Chip` / `FilterChip` / `ChoiceChip` | `GlazeFilterChipBar` (`glaze_filter_chip_bar.dart`), `GlazeDropdownChip` / `GlazeFilterIconButton` (`list_controls.dart`), `CardTagChips`, `VariationChip`, `ConnectionChip` / `ConnectionScopeChip` | Pick the one that matches the role; a bare toggle in a form is usually a `MenuSwitchItem`, not a chip. |
| `DropdownButton` / `PopupMenuButton` | `GlazeDropdownChip` + `showGlazePickerSheet` (`list_controls.dart`), or `MenuSelectorItem` inside a `MenuGroup` | |
| `TextField` | `GlazeTextField` (`glaze_text_field.dart`) standalone, `MenuFieldItem` inside a menu group, `GenericEditor` for a whole form | |
| A hand-built settings form | `GenericEditor` + `GenericEditorSection` / `GenericEditorField` (`generic_editor.dart`) | Declarative field list (`text` / `number` / `tags` / `textarea` / `select` / `switch` / `greeting_list` / `info`), renders as `MenuGroup`s, debounced save. |
| A full-screen text editor route | `FullscreenEditorScreen.show` (`fullscreen_editor.dart`) | |
| `SnackBar` | `GlazeToast.show` (`glaze_toast.dart`) | Overlay-based, so it survives a popped route. `showWithoutContext` exists for background work. |
| `AlertDialog` for a failure | `GlazeErrorDialog.show` (`glaze_error_dialog.dart`) or `GlazeErrorBlock` (`glaze_error_block.dart`) | Dialog when the error interrupts; inline block when the failure should stay on screen next to the action that caused it. |
| `AlertDialog` for a confirm | `GlazeBottomSheet.show` with `bigInfo` + destructive/cancel `items` | The app confirms in sheets, not dialogs. |
| `BottomNavigationBar` / `NavigationBar` | `GlassNavBar` (`glass_nav_bar.dart`) | Shell only. |
| A `Tooltip` explaining a term | `HelpTip` (`help_tip.dart`) | Opens the glossary at that term, and respects the `hideTooltips` setting. |
| `AnimatedDefaultTextStyle` on a counter | `RollingNumber` (`rolling_number.dart`) | |
| A raw `Scrollbar` / overscroll glow | Nothing — `GlazeScrollBehavior` (`stretch_overscroll.dart`) is applied app-wide | Do not re-add the framework stretch indicator: it renders through an offscreen layer, which kills every `BackdropFilter` inside the scroll view for the duration of the stretch. |

Supporting pieces you normally get for free (via the widgets above) but may
need directly: `GlazeBackground`, `TopEdgeBlur`, `NoiseOverlay`,
`GlowInkWell` / `GlowRippleOverlay`, `FilterSheet`, `ImageViewer`,
`FolderNameDialog`, `ConnectionSection` and friends, and the `InlineMd`
renderers in `colored_markdown.dart`.

## Which sheet

Both are correct Glaze chrome; they solve different shapes.

**`GlazeBottomSheet.show`** — a menu or a short form. You hand it declarative
content (`items`, `itemsAsCards`, `cardItems`, `sessionItems`, `bigInfo`,
`input`) or a `child`, and it renders a glass sheet with a handle, an optional
title header, and its own scroll view. Height follows the content up to 95 %.

Because its body is a `SingleChildScrollView`, `child` is laid out with an
**unbounded height** — anything needing a bounded viewport (`Expanded`,
`TabBarView`, a nested `ListView`) does not belong here.

**`SheetView`** — a screen-like sheet. Draggable between ~85 % and full height,
its own header with back button, `actions`, and a `headerBottom` slot for a tab
strip; the body gets a bounded height and the header height is handed down as
`MediaQuery.padding.top`. Present it yourself:

```dart
showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  builder: (_) => MySheet(...),
);
```

The same widget also renders as a full-screen route (it detects whether it is
inside a `ModalBottomSheetRoute`), which is why sheets and pushed sub-screens
share one class.

### The header inset

`SheetView` reports its measured header height through
`MediaQuery.padding.top`, and paints a blurred, surface-tinted strip
(`TopEdgeBlur`) that tall over the top of the body. **A scrollable body must
consume that padding**, or its first card sits under the strip and reads as a
pale veil across the content:

```dart
ListView(
  padding: EdgeInsets.fromLTRB(
    0,
    MediaQuery.paddingOf(context).top + 12,
    0,
    MediaQuery.paddingOf(context).bottom + 24,
  ),
  ...
)
```

The bottom padding is the nav-bar / keyboard inset, delivered the same way so
list rows scroll *behind* the nav bar while the last row rests above it.

That inset is deliberately **stable**: the status-bar pad the sheet fades in as
it approaches fullscreen is applied as an outer inset, not folded into the
`MediaQuery`. A `MediaQuery` that moved with the sheet rebuilt every body that
reads it, once per frame of a resize — for a big eagerly-built form that is a
whole widget tree per frame. Keep it that way: nothing that animates belongs in
the inset the body reads.

### The keyboard

A `SheetView` answers the on-screen keyboard by **tracking the inset**: it grows
by exactly what the keyboard covers (never past fullscreen) and shrinks back as
the keyboard retracts, so the visible body stays the same size and the sheet
never runs a height animation of its own alongside the system's. Dragging the
sheet, or tapping the handle, hands that lift over to the sheet's own height —
from then on the gesture moves it 1:1 and the height survives the keyboard
going away.

Do not add a second keyboard response inside a body: `SheetView` already pads
the whole body above the keyboard, so a body that insets itself by
`MediaQuery.viewInsetsOf(context).bottom` double-counts it.

## Colours

- Always through `context.cs` (`ColorScheme`) or `context.colors`
  (`GlazeColors` theme extension) from `lib/shared/theme/app_colors.dart`.
- Never a literal that duplicates a token: `context.cs.outlineVariant`, not
  `Colors.white.withValues(alpha: 0.1)`; `context.cs.primary`, not a hex.
- Literal accent colours are acceptable for **semantic status** that has no
  token — green "active", orange "needs rebuild", amber "generating", red
  "destructive". Hoist them to file-level `const` rather than repeating the hex
  inline.
- `Colors.green` / `Colors.orange` / `Colors.redAccent` &co are Material's
  palette, not Glaze's. Prefer explicit `Color(0xFF…)` constants so the accent
  is deliberate and greppable.

## Performance notes

`GlassSurface` is a `ConsumerWidget` that watches the theme preset and, unless
battery-saver is on, wraps its child in a `BackdropFilter`.

- Fine for structural chrome: a hero card, a toolbar tile, a section container,
  an empty-state box — a handful per screen.
- **Not** fine per row of a long list. A blur pass on each of fifty cards (and
  three chips inside each) is a real frame cost. List rows in this codebase use
  `Material` + `InkWell` over a `DecoratedBox` instead — see `GlazeSessionRow`
  and `_CardRow` in `glaze_bottom_sheet.dart`.

Same reasoning applies to `NoiseOverlay` and `GlowRippleOverlay`: they are
already inside `GlassSurface`, so do not stack another copy on top.

`TopEdgeBlur` (the strip `SheetView` paints over the top of its body) replaces
its child with a `toImageSync` raster of the whole child and blurs the top of
it, so **every frame on which the body moves — a scroll, a sheet resize, the
keyboard sliding in — rasterises the whole surface** to blur its top ~150 px.
Its fingerprint cache only helps while the content is still. Keep sheet bodies
off the effect's critical path where you can, and measure with
`--dart-define=NO_EDGE_BLUR=true` before blaming anything else for dropped
frames during an animation.

## Adding to the kit

Follow `docs/CODE_STYLE.md` § *UI Files*: a private helper widget belongs next
to its screen. Promote it to `lib/shared/widgets/` only once a **second**
screen needs it. A widget used by one feature but shared by several files
inside it goes in that feature's own folder — e.g.
`lib/features/chat/widgets/memory/memory_books_controls.dart`.

When you do promote one, name it `glaze_*.dart` / `Glaze*` if it is a general
primitive, and give it a doc comment saying what it replaces and why.

## Related

- `docs/CODE_STYLE.md` — when to split a UI file, what to extract from it.
- `docs/ARCHITECTURE.md` § 7 — the theme-preset system `GlassSurface` reads.
- `CLAUDE.md` § Theme, § Navigation — colour/theme file locations and the
  explicit-back-button rule for sub-screens.
