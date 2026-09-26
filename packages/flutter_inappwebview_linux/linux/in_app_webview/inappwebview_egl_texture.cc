#include "inappwebview_egl_texture.h"

#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <unistd.h>

#include "../utils/gl_context.h"
#include "../utils/log.h"
#include "in_app_webview.h"

// Use the shared HasCurrentGLContext from gl_context.h
static gboolean has_current_gl_context() {
  return flutter_inappwebview_plugin::HasCurrentGLContext() ? TRUE : FALSE;
}

/**
 * Zero-copy EGL Image texture implementation.
 *
 * This is the most performant texture implementation for WPE WebKit because:
 *
 * 1. WPE WebKit exports frames as EGL images (backed by DMA-BUF)
 * 2. We bind the EGL image directly to a GL texture using glEGLImageTargetTexture2DOES
 * 3. Flutter samples this texture directly - NO pixel copy at any point!
 *
 * The previous implementation had this flow:
 *   WPE → EGL Image → glReadPixels (GPU→CPU) → glTexImage2D (CPU→GPU) → Flutter
 *
 * This implementation has:
 *   WPE → EGL Image → GL Texture binding → Flutter
 *
 * This eliminates the glReadPixels bottleneck that was causing lag on large textures.
 */

// Private structure for the EGL texture
struct _InAppWebViewEGLTexture {
  FlTextureGL parent_instance;

  // Reference to the webview (not owned)
  flutter_inappwebview_plugin::WebViewType* webview;

  // The GL texture bound to the current EGL image
  GLuint texture_id;
  gboolean texture_initialized;
  uint32_t texture_width;   // Current texture dimensions
  uint32_t texture_height;

  // Current EGL image (weak reference - owned by WPE)
  void* current_egl_image;  // EGLImageKHR
  uint32_t width;
  uint32_t height;
  gboolean has_new_frame;

  // Fallback: pixel buffer for when EGL is not available (SHM mode)
  uint8_t* fallback_buffer;
  size_t fallback_buffer_size;

  // Default texture for when no content is available
  GLuint default_texture_id;
  gboolean default_texture_initialized;

  // Cached function pointer for EGL image binding
  PFNGLEGLIMAGETARGETTEXTURE2DOESPROC glEGLImageTargetTexture2DOES;
  gboolean extension_checked;
  gboolean extension_available;

  // GLAZE PATCH: EGLImage imported from the WebView's DMA-BUF on the EGL
  // display of Flutter's GL context, and the frame it came from.
  EGLImageKHR dmabuf_image;
  EGLDisplay dmabuf_image_display;
  uint64_t dmabuf_serial;
  gboolean dmabuf_import_failed;

  // Mutex to protect frame data access
  GMutex mutex;
};

G_DEFINE_TYPE(InAppWebViewEGLTexture, inappwebview_egl_texture, fl_texture_gl_get_type())

// Check and cache the EGL image extension availability
static gboolean check_egl_image_extension(InAppWebViewEGLTexture* self) {
  if (self->extension_checked) {
    return self->extension_available;
  }

  self->extension_checked = TRUE;

  // Check for the extension
  const char* extensions = (const char*)glGetString(GL_EXTENSIONS);
  
  if (extensions != nullptr &&
      (strstr(extensions, "GL_OES_EGL_image") != nullptr ||
       strstr(extensions, "GL_OES_EGL_image_external") != nullptr)) {
    self->glEGLImageTargetTexture2DOES =
        (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    self->extension_available = (self->glEGLImageTargetTexture2DOES != nullptr);
  } else {
    // Try to get the function pointer anyway - epoxy might handle it
    self->glEGLImageTargetTexture2DOES =
        (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    self->extension_available = (self->glEGLImageTargetTexture2DOES != nullptr);
  }

  if (self->extension_available) {
    flutter_inappwebview_plugin::debugLog(
        "InAppWebViewEGLTexture: GL_OES_EGL_image extension available - zero-copy enabled");
  } else {
    flutter_inappwebview_plugin::debugLog(
        "InAppWebViewEGLTexture: GL_OES_EGL_image extension NOT available - falling back to "
        "pixel buffer");
  }

  return self->extension_available;
}

// GLAZE PATCH: imports the WebView's current DMA-BUF frame on the EGL display
// of the GL context Flutter has current, binds it to texture_id and fills the
// out params. An EGLImage has to be created on the display of the context that
// samples it; upstream created it on WPE's headless display, which renders
// black. Returns FALSE when there is no DMA-BUF frame or it cannot be imported
// here; after a failed import the WebView is switched to copying pixels so the
// pixel-buffer fallback below gets frames.
static gboolean import_current_dmabuf(InAppWebViewEGLTexture* self, uint32_t* target,
                                      uint32_t* name, uint32_t* out_width,
                                      uint32_t* out_height) {
  if (self->dmabuf_import_failed || self->webview == nullptr) {
    return FALSE;
  }

  flutter_inappwebview_plugin::WebViewType::DmaBufFrame frame;
  if (!self->webview->GetCurrentDmaBuf(&frame)) {
    return FALSE;
  }

  auto close_fds = [&frame]() {
    for (uint32_t i = 0; i < frame.n_planes; i++) {
      close(frame.fds[i]);
    }
  };

  if (self->dmabuf_image != EGL_NO_IMAGE_KHR && frame.serial == self->dmabuf_serial) {
    close_fds();
    *target = GL_TEXTURE_2D;
    *name = self->texture_id;
    *out_width = self->texture_width;
    *out_height = self->texture_height;
    return TRUE;
  }

  EGLDisplay display = eglGetCurrentDisplay();
  if (display == EGL_NO_DISPLAY || !check_egl_image_extension(self)) {
    // Flutter is not rendering through EGL (e.g. GLX), nothing to import on.
    close_fds();
    g_warning("[flutter_inappwebview] no EGL display for DMA-BUF import, "
              "falling back to pixel copies");
    self->dmabuf_import_failed = TRUE;
    self->webview->SetSkipPixelReadback(false);
    return FALSE;
  }

  static const EGLint kFdAttrs[] = {EGL_DMA_BUF_PLANE0_FD_EXT, EGL_DMA_BUF_PLANE1_FD_EXT,
                                    EGL_DMA_BUF_PLANE2_FD_EXT, EGL_DMA_BUF_PLANE3_FD_EXT};
  static const EGLint kOffsetAttrs[] = {
      EGL_DMA_BUF_PLANE0_OFFSET_EXT, EGL_DMA_BUF_PLANE1_OFFSET_EXT,
      EGL_DMA_BUF_PLANE2_OFFSET_EXT, EGL_DMA_BUF_PLANE3_OFFSET_EXT};
  static const EGLint kPitchAttrs[] = {EGL_DMA_BUF_PLANE0_PITCH_EXT, EGL_DMA_BUF_PLANE1_PITCH_EXT,
                                       EGL_DMA_BUF_PLANE2_PITCH_EXT, EGL_DMA_BUF_PLANE3_PITCH_EXT};
  static const EGLint kModLoAttrs[] = {
      EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT,
      EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT};
  static const EGLint kModHiAttrs[] = {
      EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT,
      EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT};
  // DRM_FORMAT_MOD_INVALID: the buffer carries no explicit modifier.
  constexpr uint64_t kModifierInvalid = 0x00ffffffffffffffULL;

  EGLint attrs[6 + 10 * 4 + 1];
  int n = 0;
  attrs[n++] = EGL_WIDTH;
  attrs[n++] = static_cast<EGLint>(frame.width);
  attrs[n++] = EGL_HEIGHT;
  attrs[n++] = static_cast<EGLint>(frame.height);
  attrs[n++] = EGL_LINUX_DRM_FOURCC_EXT;
  attrs[n++] = static_cast<EGLint>(frame.fourcc);
  for (uint32_t i = 0; i < frame.n_planes; i++) {
    attrs[n++] = kFdAttrs[i];
    attrs[n++] = frame.fds[i];
    attrs[n++] = kOffsetAttrs[i];
    attrs[n++] = static_cast<EGLint>(frame.offsets[i]);
    attrs[n++] = kPitchAttrs[i];
    attrs[n++] = static_cast<EGLint>(frame.strides[i]);
    if (frame.modifier != kModifierInvalid) {
      attrs[n++] = kModLoAttrs[i];
      attrs[n++] = static_cast<EGLint>(frame.modifier & 0xffffffff);
      attrs[n++] = kModHiAttrs[i];
      attrs[n++] = static_cast<EGLint>(frame.modifier >> 32);
    }
  }
  attrs[n++] = EGL_NONE;

  EGLImageKHR image =
      eglCreateImageKHR(display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nullptr, attrs);
  // The EGLImage holds its own references to the buffer.
  close_fds();

  if (image == EGL_NO_IMAGE_KHR) {
    // g_warning rather than errorLog: release builds should still say why
    // the WebView went to the slower path.
    g_warning("[flutter_inappwebview] DMA-BUF import failed (EGL error 0x%x), "
              "falling back to pixel copies",
              eglGetError());
    self->dmabuf_import_failed = TRUE;
    self->webview->SetSkipPixelReadback(false);
    return FALSE;
  }

  if (!self->texture_initialized) {
    glGenTextures(1, &self->texture_id);
    self->texture_initialized = TRUE;
  }
  glBindTexture(GL_TEXTURE_2D, self->texture_id);
  self->glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, static_cast<GLeglImageOES>(image));
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glBindTexture(GL_TEXTURE_2D, 0);

  // The texture keeps the new image's storage; the previous image can go.
  if (self->dmabuf_image != EGL_NO_IMAGE_KHR) {
    eglDestroyImageKHR(self->dmabuf_image_display, self->dmabuf_image);
  }
  self->dmabuf_image = image;
  self->dmabuf_image_display = display;
  self->dmabuf_serial = frame.serial;
  self->texture_width = frame.width;
  self->texture_height = frame.height;

  *target = GL_TEXTURE_2D;
  *name = self->texture_id;
  *out_width = frame.width;
  *out_height = frame.height;
  return TRUE;
}

// Populate callback - called by Flutter to get the OpenGL texture
static gboolean inappwebview_egl_texture_populate(FlTextureGL* texture, uint32_t* target,
                                                  uint32_t* name, uint32_t* out_width,
                                                  uint32_t* out_height, GError** error) {
  InAppWebViewEGLTexture* self = INAPPWEBVIEW_EGL_TEXTURE(texture);

  g_mutex_lock(&self->mutex);

  // CRITICAL: Verify we have a current GL context before any GL operations.
  if (!has_current_gl_context()) {
    // Return cached texture if available
    if (self->texture_initialized && self->texture_id != 0) {
      *target = GL_TEXTURE_2D;
      *name = self->texture_id;
      *out_width = self->texture_width > 0 ? self->texture_width : 1;
      *out_height = self->texture_height > 0 ? self->texture_height : 1;
      g_mutex_unlock(&self->mutex);
      return TRUE;
    }

    // Return default texture if available
    if (self->default_texture_initialized && self->default_texture_id != 0) {
      *target = GL_TEXTURE_2D;
      *name = self->default_texture_id;
      *out_width = 1;
      *out_height = 1;
      g_mutex_unlock(&self->mutex);
      return TRUE;
    }

    g_mutex_unlock(&self->mutex);
    g_set_error(error, g_quark_from_static_string("InAppWebViewEGLTexture"), 1,
                "No EGL/GL context current - will retry");
    return FALSE;
  }

  if (import_current_dmabuf(self, target, name, out_width, out_height)) {
    self->has_new_frame = FALSE;
    g_mutex_unlock(&self->mutex);
    return TRUE;
  }

  // Use the EGL image that was set via inappwebview_egl_texture_set_egl_image()
  // This is updated by the on_frame_available callback before Flutter is notified
  if (self->current_egl_image != nullptr && self->width > 0 && self->height > 0) {
    // Check if EGL image extension is available
    if (check_egl_image_extension(self)) {
      // Create texture if needed
      if (!self->texture_initialized) {
        glGenTextures(1, &self->texture_id);
        self->texture_initialized = TRUE;
      }

      // Bind the EGL image to our texture - ZERO-COPY!
      glBindTexture(GL_TEXTURE_2D, self->texture_id);
      self->glEGLImageTargetTexture2DOES(GL_TEXTURE_2D,
                                         static_cast<GLeglImageOES>(self->current_egl_image));

      // Set texture parameters
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

      glBindTexture(GL_TEXTURE_2D, 0);

      // Update tracked dimensions
      self->texture_width = self->width;
      self->texture_height = self->height;

      *target = GL_TEXTURE_2D;
      *name = self->texture_id;
      *out_width = self->width;
      *out_height = self->height;
      
      self->has_new_frame = FALSE;

      g_mutex_unlock(&self->mutex);
      return TRUE;
    }
  }

  // Fallback: Try to get pixel buffer from webview (SHM mode)
  if (self->webview != nullptr) {
    uint32_t buf_width = 0;
    uint32_t buf_height = 0;
    size_t required_size = self->webview->GetPixelBufferSize(&buf_width, &buf_height);

    if (required_size > 0 && buf_width > 0 && buf_height > 0) {
      static bool first_fallback = true;
      if (first_fallback) {
        flutter_inappwebview_plugin::debugLog(
            "InAppWebViewEGLTexture: using pixel buffer fallback (SHM mode), size=" +
            std::to_string(buf_width) + "x" + std::to_string(buf_height));
        first_fallback = false;
      }

      // Reallocate fallback buffer if needed
      if (self->fallback_buffer_size < required_size) {
        self->fallback_buffer = static_cast<uint8_t*>(g_realloc(self->fallback_buffer, required_size));
        self->fallback_buffer_size = required_size;
      }

      if (self->fallback_buffer != nullptr) {
        // Copy pixel data from webview
        if (self->webview->CopyPixelBufferTo(self->fallback_buffer, self->fallback_buffer_size,
                                             &buf_width, &buf_height)) {
          // Create texture if needed
          if (!self->texture_initialized) {
            glGenTextures(1, &self->texture_id);
            self->texture_initialized = TRUE;
          }

          // Upload pixel data to texture
          glBindTexture(GL_TEXTURE_2D, self->texture_id);
          
          // Use glTexSubImage2D if size hasn't changed, otherwise glTexImage2D
          if (self->texture_width == buf_width && self->texture_height == buf_height) {
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, buf_width, buf_height,
                            GL_RGBA, GL_UNSIGNED_BYTE, self->fallback_buffer);
          } else {
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, buf_width, buf_height, 0,
                         GL_RGBA, GL_UNSIGNED_BYTE, self->fallback_buffer);
            self->texture_width = buf_width;
            self->texture_height = buf_height;
          }

          glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
          glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
          glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
          glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

          glBindTexture(GL_TEXTURE_2D, 0);

          *target = GL_TEXTURE_2D;
          *name = self->texture_id;
          *out_width = buf_width;
          *out_height = buf_height;

          g_mutex_unlock(&self->mutex);
          return TRUE;
        }
      }
    }
  }

  // No frame available yet, use default 1x1 transparent texture
  if (!self->default_texture_initialized) {
    glGenTextures(1, &self->default_texture_id);
    glBindTexture(GL_TEXTURE_2D, self->default_texture_id);
    uint8_t pixel[4] = {0, 0, 0, 0};  // Transparent
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    self->default_texture_initialized = TRUE;
  }

  *target = GL_TEXTURE_2D;
  *name = self->default_texture_id;
  *out_width = 1;
  *out_height = 1;

  g_mutex_unlock(&self->mutex);
  return TRUE;
}

static void inappwebview_egl_texture_dispose(GObject* object) {
  InAppWebViewEGLTexture* self = INAPPWEBVIEW_EGL_TEXTURE(object);

  g_mutex_lock(&self->mutex);

  // Free fallback buffer
  if (self->fallback_buffer != nullptr) {
    g_free(self->fallback_buffer);
    self->fallback_buffer = nullptr;
    self->fallback_buffer_size = 0;
  }

  // Note: We don't call glDeleteTextures here because:
  // 1. The GL context may not be current
  // 2. Flutter's texture registrar will handle texture cleanup
  self->texture_id = 0;
  self->texture_initialized = FALSE;
  self->texture_width = 0;
  self->texture_height = 0;
  self->default_texture_id = 0;
  self->default_texture_initialized = FALSE;
  self->current_egl_image = nullptr;

  // Destroying an EGLImage needs its display, not a current context.
  if (self->dmabuf_image != EGL_NO_IMAGE_KHR) {
    eglDestroyImageKHR(self->dmabuf_image_display, self->dmabuf_image);
    self->dmabuf_image = EGL_NO_IMAGE_KHR;
  }

  g_mutex_unlock(&self->mutex);
  g_mutex_clear(&self->mutex);

  G_OBJECT_CLASS(inappwebview_egl_texture_parent_class)->dispose(object);
}

static void inappwebview_egl_texture_class_init(InAppWebViewEGLTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = inappwebview_egl_texture_populate;
  G_OBJECT_CLASS(klass)->dispose = inappwebview_egl_texture_dispose;
}

static void inappwebview_egl_texture_init(InAppWebViewEGLTexture* self) {
  self->webview = nullptr;
  self->texture_id = 0;
  self->texture_initialized = FALSE;
  self->texture_width = 0;
  self->texture_height = 0;
  self->current_egl_image = nullptr;
  self->width = 0;
  self->height = 0;
  self->has_new_frame = FALSE;
  self->fallback_buffer = nullptr;
  self->fallback_buffer_size = 0;
  self->default_texture_id = 0;
  self->default_texture_initialized = FALSE;
  self->glEGLImageTargetTexture2DOES = nullptr;
  self->extension_checked = FALSE;
  self->extension_available = FALSE;
  self->dmabuf_image = EGL_NO_IMAGE_KHR;
  self->dmabuf_image_display = EGL_NO_DISPLAY;
  self->dmabuf_serial = 0;
  self->dmabuf_import_failed = FALSE;
  g_mutex_init(&self->mutex);
}

InAppWebViewEGLTexture* inappwebview_egl_texture_new(
    flutter_inappwebview_plugin::WebViewType* webview) {
  InAppWebViewEGLTexture* self =
      INAPPWEBVIEW_EGL_TEXTURE(g_object_new(INAPPWEBVIEW_TYPE_EGL_TEXTURE, nullptr));
  self->webview = webview;
  flutter_inappwebview_plugin::debugLog("InAppWebViewEGLTexture: created (zero-copy mode)");
  return self;
}

void inappwebview_egl_texture_set_egl_image(InAppWebViewEGLTexture* self, void* egl_image,
                                            uint32_t width, uint32_t height) {
  if (self == nullptr) {
    return;
  }

  g_mutex_lock(&self->mutex);

  self->current_egl_image = egl_image;
  self->width = width;
  self->height = height;
  self->has_new_frame = TRUE;

  g_mutex_unlock(&self->mutex);
}
