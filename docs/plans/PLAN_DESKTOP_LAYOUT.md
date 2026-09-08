# Port the Vue PC (desktop) layout to Flutter

> Status: done — implemented in `lib/shared/shell/desktop/` (`desktop_shell.dart`,
> `desktop_left_sidebar.dart`, `desktop_right_sidebar.dart`, etc.). Activates at
> width ≥ 768; `router.dart` redirects `/` → `/characters` on desktop.

## Context

Glaze's Vue app has a rich **desktop layout** (`src/App.vue`, `DesktopLeftSidebar.vue`,
`DesktopRightSidebar.vue`) that activates at `window.innerWidth >= 768`:

- A three-column shell: **left sidebar** (chat list + nav, replacing the bottom nav) │
  **center** (active view / chat) │ **right sidebar** (Tools when browsing, MagicDrawer in chat).
- Both sidebars are **resizable** and **collapsible** (drag handles, icon-only strips with
  hover tooltips when narrow), with widths persisted to `localStorage`.
- Chat renders **in the center** while sidebars stay persistent.
- "Menu-family" views (menu, settings, theme settings, sync, backup) render as **floating
  centered overlay windows** instead of replacing the center; the glossary is a **draggable
  corner popup**.
- Bottom sheets render **inside the right sidebar** (`sidebar-mode`), and the right sidebar
  **auto-expands** when a sheet/sub-view opens, then restores.

GlazeFlutter currently has **no desktop layout** — it is mobile-first: a GoRouter
`StatefulShellRoute` with a `GlassNavBar` bottom nav (4 branches: `/`, `/characters`,
`/tools`, `/menu`), and chat as a separate full-screen WebView route `/chat/:charId`.

**Goal (confirmed with user): full faithful 1:1 port, with chat embedded in the center column.**
Because this is large, it is structured into phases that build on each other. Each phase is
independently shippable and verifiable; later phases are the cross-cutting ones.

Breakpoint and behavior mirror Vue exactly: desktop = logical width `>= 768` AND not
`forceMobileLayout`; on entering desktop the default center view is **characters** (the chats
list lives in the left sidebar). Persistence keys reuse the Vue names so behavior matches:
`gz_left_sidebar_width`(+`_collapsed`), `gz_right_sidebar_width`,
`gz_right_sidebar_collapsed_width`, `gz_right_sidebar_width_collapsed`.

## Key reuse points (existing Flutter code)

- `sharedPreferencesProvider` — `lib/core/state/shared_prefs_provider.dart` (localStorage analog for widths).
- `MagicDrawerPanel` — `lib/features/chat/widgets/magic_drawer.dart` (already a self-contained
  panel taking `charId` + `onClose`; this is exactly the right-sidebar chat content).
- `ChatHistoryScreen` list internals — `lib/features/chat_history/chat_history_screen.dart`
  (extract the list body into a reusable widget for the left sidebar).
- `ToolsScreen` — `lib/features/tools/tools_screen.dart` (right-sidebar non-chat content).
- `GlassSurface` / `GlassNavBar` / `app_colors.dart` (`context.cs`, `context.colors`) — shared theme.
- `ShellScreen` + `shellHeaderProvider` (`resolveShellHeader`) — current chrome/header to make desktop-aware.
- Router: `buildRouter` in `lib/core/navigation/router.dart`.
- Screens reused as overlay content: `MenuScreen`, `AppSettingsScreen`, `ThemePresetScreen`,
  `SyncSheet`, `BackupScreen`, `GlossarySheet`.

---

## Phase 0 — Desktop detection + resizer primitives

New dir: `lib/shared/shell/desktop/`

- `desktop_layout_provider.dart`
  - `forceMobileLayoutProvider` — reads the `forceMobileLayout` flag from app settings
    (`AppSettings` in `lib/features/settings/app_settings_provider.dart`; add the field +
    persistence + a Settings toggle if absent — mirrors Vue `forceMobileLayout`).
  - `isDesktopProvider` (`StateProvider<bool>`), updated by `DesktopShell`'s `LayoutBuilder`
    each layout pass: `width >= 768 && !forceMobileLayout`. Helper
    `isDesktopLayout(ref)` for read sites.
- `sidebar_resizer.dart` — faithful port of `useSidebarResizer.js`:
  - `LeftSidebarController` (single width; threshold 120, collapsed 64, min 200, max 600,
    default 280; `collapsed = width < 120`; persists `gz_left_sidebar_width` + `_collapsed`).
  - `RightSidebarController` (two **independent** widths per `DesktopRightSidebar.vue`:
    expanded default 300 / min 200 / max 800, collapsed default 64 / min 48; threshold 120;
    persists the three `gz_right_*` keys; supports programmatic auto-expand/restore).
  - Backed by `SharedPreferences`; exposed as `ChangeNotifier`/`Notifier` so sidebars rebuild on drag.
- `sidebar_drag_handle.dart` — reusable vertical handle: `MouseRegion(cursor: resizeColumn)`
  + `GestureDetector(onHorizontalDragUpdate/End)` translating dx into width via the controller
  (left handle adds dx, right handle subtracts — same sign rules as Vue).

`flutter analyze` after this phase (no UI wired yet besides providers).

---

## Phase 1 — Three-column desktop shell + left sidebar

**Routing change** (`router.dart`): wrap the whole route tree in an outer `ShellRoute` whose
builder renders `DesktopShell(child: child)`. The StatefulShellRoute, `/chat/:charId`, and the
other top-level routes become its sub-routes, so the desktop chrome (sidebars + header) is
persistent across **all** of them including chat. `rootNavigatorKey` stays the outer navigator.

- `desktop_shell.dart`
  - `LayoutBuilder` → updates `isDesktopProvider`.
  - **Mobile**: return `child` unchanged (existing `ShellScreen` bottom-nav behavior preserved).
  - **Desktop**: `Row[ DesktopLeftSidebar | Expanded(child=center) | DesktopRightSidebar ]`
    with the persistent header floated on top (Stack), background via existing `GlazeBackground`.
  - Make `ShellScreen` desktop-aware: on desktop it renders only the branch container (no
    `GlassNavBar`, no its own background/header — those move to `DesktopShell`); the desktop
    header is a single shell-level header driven by `shellHeaderProvider`/chat header.
- `desktop_left_sidebar.dart` (port of `DesktopLeftSidebar.vue`)
  - Top nav: **Characters** button (→ `/characters`), **New Chat** button (opens the new-chat
    picker — reuse the character picker path used by the `+` FAB).
  - Middle: the **chats list** — extract `ChatHistoryScreen`'s list body into
    `ChatHistoryList({bool collapsed})` (new widget in `chat_history/`) and embed it; reuse
    `chatHistoryProvider`, `_SessionTile`. Tapping a session → `context.go('/chat/...')`.
  - Bottom nav: **Glossary** + **More** buttons.
  - Collapsed (`width < 120`): icon-only column; hover shows tooltip via `ToolStripTooltip`.
  - Right-edge `SidebarDragHandle` bound to `LeftSidebarController`.
- Center "empty" state: on `/` (chats) at desktop, the chats list is in the sidebar, so the
  center shows a "Select a chat" placeholder (matches Vue, where `view-dialogs` is suppressed
  in main on desktop). Default desktop center = `/characters`.
- `tool_strip_tooltip.dart` — port of `ToolStripTooltip.vue` (an `OverlayPortal`/`Tooltip`-style
  hover label positioned to the side of collapsed icons).

Verify: on a wide Windows window, left sidebar replaces bottom nav; resize/collapse persists
across restart; navigation between characters/tools works in the center.

---

## Phase 2 — Right sidebar (Tools / MagicDrawer) + chat in center

- `desktop_right_sidebar.dart` (port of `DesktopRightSidebar.vue`)
  - **Chat mode** (location starts with `/chat/`): host `MagicDrawerPanel(charId)` when expanded;
    icon-only strip (from `MagicDrawerPanel`'s item list) when collapsed.
  - **Non-chat mode**: `ToolsScreen` as the background + active tool panel; collapsed → tool
    icon strip (Personas/Presets/API/Lorebook/Regex, paths already in `tools_screen.dart`).
  - Two-width resize via `RightSidebarController`; left-edge `SidebarDragHandle`.
- **Chat embedded in center** (the largest single change):
  - Keep `/chat/:charId` as the route, but since it's now inside the outer `ShellRoute`, on
    desktop its content renders in the center column with sidebars persistent.
  - Make `ChatScreen` desktop-aware: when desktop, **hide its own MagicDrawer / drawer
    controller** (the drawer now lives in the right sidebar) and let its header be the
    shell header. The keep-alive WebView (`ChatWebViewPreloader`, `_everBuiltBody`) is
    untouched — it just lives in a narrower center column. Reuse `chat_webview_widget.dart` as-is.
  - The right sidebar's MagicDrawer reads the active `charId` from the route
    (`activeChatCharId` derived from GoRouter location, or `activeSelectionProvider`).

Verify: opening a chat keeps both sidebars; MagicDrawer in the right sidebar drives the chat;
WebView is not recreated on session switch (existing keep-alive holds).

---

## Phase 3 — Auto-expand on sheet + collapse polish

- Port the `DesktopRightSidebar.vue` auto-expand logic: a `rightSidebarSheetProvider`
  (bool/occupied) that, when a sheet/sub-view opens while collapsed, expands the sidebar and
  restores collapse on close (`wasAutoExpanded` flag in `RightSidebarController`).
- Finalize collapsed icon strips for both sidebars with the Vue styling
  (`tools-strip`/`magic-item` look) using `GlassSurface` + `app_colors`.

---

## Phase 4 — Floating windows + glossary corner popup

On desktop, the "menu-family" views (`menu`, `settings`, `theme-settings`, `sync`, `backup`)
must float as centered overlay windows over a stable center (Vue `WindowView` +
`isDesktopFloating`, `menuViews`).

- `desktop_floating_provider.dart` — `DesktopFloatingController` (Notifier) holding an optional
  floating view id + nav stack.
- `desktop_window_view.dart` — centered glass overlay panel (port of `WindowView.vue`) rendered
  by `DesktopShell` when the controller is set; content = reused `MenuScreen` /
  `AppSettingsScreen` / `ThemePresetScreen` / `SyncSheet` / `BackupScreen`.
- On desktop, the left sidebar **More/Glossary** buttons and in-app links to settings/sync/
  backup/theme set the floating controller instead of `context.go/push` (a small `goOrFloat`
  helper keyed off `isDesktopLayout`); mobile keeps routing unchanged.
- `desktop_glossary_popup.dart` — draggable corner popup (port of the `desktop-glossary-popup`
  block in `App.vue` + `useGlossaryPopup.js`): drag header, back/close, content = `GlossarySheet`.

---

## Phase 5 — Bottom sheets inside the right sidebar (cross-cutting)

Vue renders bottom sheets in the right sidebar (`sidebar-mode`) on desktop. In Flutter, chat/
tools sheets use `showModalBottomSheet`/`GlazeBottomSheet`. Introduce one adaptive entry point
and migrate the chat + tools call sites:

- `showAdaptiveSheet(context, ref, builder)` + a `sidebarSheetHostProvider`: on desktop, push
  the builder's content into the right-sidebar host (with auto-expand from Phase 3); on mobile,
  delegate to the existing modal sheet. Add a `sidebarMode` flag to `DrawerPanelScaffold` /
  sheet scaffolds so padding/close affordances adapt.
- Migrate the `MagicDrawerPanel._handleTap` sheet calls (sessions, tokenizer, summary, stats,
  char-card, lorebooks, regex, api, presets, personas, image-gen, authors-note, ext-blocks) and
  the tools sub-screens to `showAdaptiveSheet`. Largest mechanical change; do last.

---

## Files (new)

```
lib/shared/shell/desktop/
  desktop_layout_provider.dart
  sidebar_resizer.dart
  sidebar_drag_handle.dart
  tool_strip_tooltip.dart
  desktop_shell.dart
  desktop_left_sidebar.dart
  desktop_right_sidebar.dart
  desktop_floating_provider.dart        (Phase 4)
  desktop_window_view.dart              (Phase 4)
  desktop_glossary_popup.dart           (Phase 4)
lib/features/chat_history/chat_history_list.dart   (extracted list body)
```

## Files (modified)

- `lib/core/navigation/router.dart` — wrap tree in outer `ShellRoute` → `DesktopShell`.
- `lib/shared/shell/shell_screen.dart` — desktop-aware (drop bottom nav/header on desktop).
- `lib/features/chat/chat_screen.dart` — desktop-aware (drawer in sidebar, shell header).
- `lib/features/chat_history/chat_history_screen.dart` — delegate body to `ChatHistoryList`.
- `lib/features/settings/app_settings_provider.dart` — add `forceMobileLayout` (if absent).
- `lib/main.dart` — only lock orientation on mobile platforms.
- Sheet call sites in `magic_drawer.dart` + tools sub-screens (Phase 5).

## Verification

- I cannot run the GUI (`flutter run` is blocked); after each phase I run
  `flutter analyze` (full path fallback `& "Z:\GlazeProject\flutter\bin\flutter.bat"` if not on
  PATH — note: memory says Flutter is actually on PATH at `F:\General\FlutterSDK`) and
  `flutter test`, then ask you to run `flutter run -d windows` and confirm:
  1. Wide window → 3-column layout, bottom nav gone; narrow (<768) → original mobile layout.
  2. Drag handles resize; dragging below threshold collapses to icon strip; widths survive restart.
  3. Chat opens in the center with both sidebars; MagicDrawer in the right sidebar works; no
     WebView flicker on session switch.
  4. Phase 4: menu/settings/sync/backup/theme open as floating windows; glossary as draggable popup.
  5. Phase 5: chat/tools sheets appear inside the right sidebar with auto-expand.
- Existing widget tests (`test/`) must stay green at mobile size; add a desktop-shell test that
  pumps at width 1200 and asserts sidebars present / nav bar absent.

## Delivery note

This is an epic. Implement and submit **phase by phase** (each its own commit/PR off
`master` per `docs/WORKFLOW.md`), pausing after Phases 0–2 (the structural core) for a Windows
verification pass before proceeding to 3–5.
