#include <stdlib.h>

#include "my_application.h"

int main(int argc, char** argv) {
  // The Linux WPE backend of flutter_inappwebview publishes each WebView frame
  // to Flutter through a zero-copy EGL/DMA-BUF texture. On several GPU drivers
  // that texture comes out black, so every WebView (chat, catalog logins,
  // extension engines) paints as a blank black area. Force the plugin's CPU
  // pixel-buffer texture instead: it copies each frame, which is slower, but
  // renders everywhere. Set GLAZE_LINUX_WEBVIEW_GL=1 to opt back into the
  // hardware texture, or pre-set FLUTTER_INAPPWEBVIEW_LINUX_DISABLE_GL.
  const char* use_gl = getenv("GLAZE_LINUX_WEBVIEW_GL");
  const gboolean hardware_gl =
      use_gl != nullptr && (g_strcmp0(use_gl, "1") == 0 ||
                            g_ascii_strcasecmp(use_gl, "true") == 0);
  if (!hardware_gl &&
      getenv("FLUTTER_INAPPWEBVIEW_LINUX_DISABLE_GL") == nullptr) {
    setenv("FLUTTER_INAPPWEBVIEW_LINUX_DISABLE_GL", "1", 0);
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
