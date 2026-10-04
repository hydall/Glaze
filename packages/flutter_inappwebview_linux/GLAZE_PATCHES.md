# Glaze patches

Vendored from `flutter_inappwebview_linux` 0.1.0-beta.1 (pub.dev) and wired in
through `dependency_overrides` in the app's `pubspec.yaml`. The first commit
that added this directory is the unmodified release; `git log -p` on this
directory shows every change since. Patched spots are marked `GLAZE PATCH`.

## DMA-BUF frames: import on Flutter's EGL display

With the WPEPlatform backend, WebKit hands each frame over as a DMA-BUF.

- Upstream imported it with `wpe_buffer_import_to_egl_image`, which creates
  the EGLImage on the headless WPE display, then bound that image inside
  Flutter's GL context. The two contexts are on different EGLDisplays, and on
  Mesa (seen on Intel Iris Xe, Wayland) the texture samples as black.
- The GL texture now takes the buffer's fds, format, strides, offsets and
  modifier (`InAppWebView::GetCurrentDmaBuf`) and creates the EGLImage itself
  with `EGL_LINUX_DMA_BUF_EXT` on `eglGetCurrentDisplay()`, so it is still
  zero-copy.
- If that import fails, or Flutter is not on EGL, the WebView switches to
  copying pixels (`wpe_buffer_import_to_pixels`) and the texture's existing
  pixel-buffer fallback draws them. A `g_warning` says so.
- Upstream also ran the WPE-display import with the pixel-buffer texture
  (`FLUTTER_INAPPWEBVIEW_LINUX_DISABLE_GL=1`), which left the pixel buffer
  empty and the WebView blank. A DMA-BUF frame now goes to the pixel import in
  that mode.

Drop this patch once upstream imports DMA-BUF frames on the consumer's
display.
