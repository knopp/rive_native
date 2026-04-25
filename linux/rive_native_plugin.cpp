// Linux Flutter plugin for rive_native
// Uses FlTextureGL with shared GDK GL context for zero-copy texture sharing.

#include "include/rive_native/rive_native_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Enable GL extension prototypes before including GL headers
#define GL_GLEXT_PROTOTYPES
#include <GL/gl.h>
#include <GL/glext.h>
#include <GL/glx.h>

#include <cstring>
#include <map>
#include <memory>
#include <sys/utsname.h>

// Forward declarations for rive_native library functions.
// These are implemented in rive_native_linux.cpp (linked from the static lib).
#include "rive_native/read_write_ring.hpp"

class FlutterRenderer;
namespace rive
{
class RenderPath;
class Factory;
class AudioSound;
} // namespace rive

#define EXPORT                                                                 \
    extern "C" __attribute__((visibility("default"))) __attribute__((used))

EXPORT void* loadRiveFile(const uint8_t* bytes, uint64_t length);
EXPORT void deleteFlutterRenderer(FlutterRenderer* renderer);
EXPORT void rewindRenderPath(rive::RenderPath* path);
EXPORT void* disposeYogaStyle(void* style);
EXPORT void riveFontDummyLinker();
#ifdef RIVE_WITH_SCRIPTING
EXPORT void riveLuaDummyLinker();
#endif
EXPORT void stopAudioSound(rive::AudioSound* sound, uint64_t timeInFrames);

extern "C"
{
    // From rive_native_linux.cpp
    void* createRiveRendererContext(void* gpu);
    void destroyRiveRendererContext(void* context);
    void* factoryFromRiveRendererContext(void* context);
    void setLinuxMakeCurrentCallback(void (*callback)(void*), void* userData);
    void* createRiveRenderer(void* textureRegistry,
                             void* riveRendererContext,
                             void* queue,
                             ReadWriteRing* ring,
                             void* texture0,
                             void* texture1,
                             void* texture2,
                             uint32_t width,
                             uint32_t height);
    void destroyRiveRenderer(void* renderer);
}

// ==================== RiveNativeGLTexture - FlTextureGL subclass ===========
// Triple-buffered GL texture for zero-copy sharing with Flutter's compositor.
// Returns the texture at ring->currentRead() in populate().

G_DECLARE_FINAL_TYPE(RiveNativeGLTexture,
                     rive_native_gl_texture,
                     RIVE_NATIVE,
                     GL_TEXTURE,
                     FlTextureGL)

struct _RiveNativeGLTexture
{
    FlTextureGL parent_instance;
    ReadWriteRing* ring;
    uint32_t gl_texture_ids[3];
    uint32_t width;
    uint32_t height;
};

G_DEFINE_TYPE(RiveNativeGLTexture,
              rive_native_gl_texture,
              fl_texture_gl_get_type())

static gboolean rive_native_gl_texture_populate(FlTextureGL* texture,
                                                uint32_t* target,
                                                uint32_t* name,
                                                uint32_t* width,
                                                uint32_t* height,
                                                GError** error)
{
    RiveNativeGLTexture* self = RIVE_NATIVE_GL_TEXTURE(texture);

    *target = GL_TEXTURE_2D;
    *name = self->gl_texture_ids[self->ring->currentRead()];
    *width = self->width;
    *height = self->height;

    return TRUE;
}

static void rive_native_gl_texture_class_init(RiveNativeGLTextureClass* klass)
{
    FL_TEXTURE_GL_CLASS(klass)->populate = rive_native_gl_texture_populate;
}

static void rive_native_gl_texture_init(RiveNativeGLTexture* self)
{
    self->ring = nullptr;
    self->gl_texture_ids[0] = 0;
    self->gl_texture_ids[1] = 0;
    self->gl_texture_ids[2] = 0;
    self->width = 0;
    self->height = 0;
}

static RiveNativeGLTexture* rive_native_gl_texture_new(void)
{
    return RIVE_NATIVE_GL_TEXTURE(
        g_object_new(rive_native_gl_texture_get_type(), nullptr));
}

// ==================== Texture info struct ==================================

/// Callback struct passed to the native renderer via the `queue` parameter.
/// The native renderer calls endCallback after glFlush() to notify Flutter,
/// and makeCurrentCallback before rendering to ensure GL context is active.
struct LinuxRendererCallbacks
{
    void (*endCallback)(void* userData);
    void (*makeCurrentCallback)(void* userData);
    void* userData;
};

struct RiveNativeTextureInfo
{
    int64_t texture_id; // Flutter texture ID
    FlTextureRegistrar* texture_registrar;
    RiveNativeGLTexture* gl_texture;
    GdkGLContext* shared_gl_context; // For making GL context current

    uint32_t gl_texture_ids[3]; // GL texture IDs
    uint32_t gl_fbos[3];        // GL framebuffer objects (for cleanup)
    ReadWriteRing ring;
    LinuxRendererCallbacks callbacks;

    void* rive_renderer; // LinuxGLRenderer*
    int width;
    int height;
};

// ==================== RiveNativePlugin =====================================

#define RIVE_NATIVE_PLUGIN(obj)                                                \
    (G_TYPE_CHECK_INSTANCE_CAST((obj),                                         \
                                rive_native_plugin_get_type(),                 \
                                RiveNativePlugin))

struct _RiveNativePlugin
{
    GObject parent_instance;
    FlPluginRegistrar* registrar;
    FlMethodChannel* channel;
    std::map<int64_t, std::unique_ptr<RiveNativeTextureInfo>>* textures;

    // Shared GL context created from FlView's GdkWindow.
    // This shares GL objects with Flutter's own GL context.
    GdkGLContext* shared_gl_context;
    // Second GL context for the Dart FFI/rendering thread.
    // Shares resources with the first context (same share group).
    GdkGLContext* ffi_gl_context;
    bool shared_context_initialized;

    // Rive renderer context (wraps RenderContextGLImpl).
    void* rive_renderer_context;
};

G_DEFINE_TYPE(RiveNativePlugin, rive_native_plugin, g_object_get_type())

// Global make-current callback for riveFactory()/riveLock().
static void on_global_make_current(void* userData)
{
    GdkGLContext* ctx = (GdkGLContext*)userData;
    if (ctx)
    {
        gdk_gl_context_make_current(ctx);
    }
}

// Callback from the native renderer before rendering begins.
// Makes the FFI GL context current on the rendering thread.
static void on_make_current(void* userData)
{
    auto* info = (RiveNativeTextureInfo*)userData;
    if (info && info->shared_gl_context)
    {
        gdk_gl_context_make_current(info->shared_gl_context);
    }
}

// Callback from the native renderer after glFlush() + ring advance.
// Marks the Flutter texture frame as available for compositing.
static void on_renderer_end(void* userData)
{
    auto* info = (RiveNativeTextureInfo*)userData;
    if (info && info->texture_registrar && info->gl_texture)
    {
        fl_texture_registrar_mark_texture_frame_available(
            info->texture_registrar,
            FL_TEXTURE(info->gl_texture));
    }
}

// Initialize shared GL context from FlView's GdkWindow.
// This creates a context that shares textures with Flutter's GL renderer.
static bool rive_native_plugin_init_shared_context(RiveNativePlugin* self)
{
    if (self->shared_context_initialized)
    {
        return self->shared_gl_context != nullptr;
    }
    self->shared_context_initialized = true;

    FlView* view = fl_plugin_registrar_get_view(self->registrar);
    if (!view)
    {
        g_warning("rive_native: No FlView available (headless mode?)");
        return false;
    }

    GtkWidget* widget = GTK_WIDGET(view);
    if (!gtk_widget_get_realized(widget))
    {
        gtk_widget_realize(widget);
    }

    GdkWindow* gdk_window = gtk_widget_get_window(widget);
    if (!gdk_window)
    {
        g_warning("rive_native: No GdkWindow available");
        return false;
    }

    GError* error = nullptr;
    self->shared_gl_context = gdk_window_create_gl_context(gdk_window, &error);
    if (error)
    {
        g_warning("rive_native: Failed to create GdkGLContext: %s",
                  error->message);
        g_error_free(error);
        return false;
    }

    if (!gdk_gl_context_realize(self->shared_gl_context, &error))
    {
        g_warning("rive_native: Failed to realize GdkGLContext: %s",
                  error->message);
        g_error_free(error);
        g_object_unref(self->shared_gl_context);
        self->shared_gl_context = nullptr;
        return false;
    }

    // Create a second GL context for the Dart FFI thread.
    // Both contexts share GL resources (textures, buffers) because they're
    // created from the same GdkWindow (same GLX share group).
    error = nullptr;
    self->ffi_gl_context = gdk_window_create_gl_context(gdk_window, &error);
    if (error)
    {
        g_warning("rive_native: Failed to create FFI GdkGLContext: %s",
                  error->message);
        g_error_free(error);
    }
    else if (!gdk_gl_context_realize(self->ffi_gl_context, &error))
    {
        g_warning("rive_native: Failed to realize FFI GdkGLContext: %s",
                  error->message);
        g_error_free(error);
        g_object_unref(self->ffi_gl_context);
        self->ffi_gl_context = nullptr;
    }

    return true;
}

// Make the shared context current.
static bool rive_native_plugin_make_context_current(RiveNativePlugin* self)
{
    if (!self->shared_gl_context)
        return false;
    gdk_gl_context_make_current(self->shared_gl_context);
    return true;
}

// Create triple GL textures for a render target.
static bool create_gl_textures(uint32_t width,
                               uint32_t height,
                               uint32_t* out_texture_ids,
                               uint32_t* out_fbo_ids)
{
    for (int i = 0; i < 3; i++)
    {
        glGenTextures(1, &out_texture_ids[i]);
        glBindTexture(GL_TEXTURE_2D, out_texture_ids[i]);
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, width, height);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        // Clear the texture to transparent black.
        out_fbo_ids[i] = 0;
        glGenFramebuffers(1, &out_fbo_ids[i]);
        glBindFramebuffer(GL_FRAMEBUFFER, out_fbo_ids[i]);
        glFramebufferTexture2D(GL_FRAMEBUFFER,
                               GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D,
                               out_texture_ids[i],
                               0);
        glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
        glClear(GL_COLOR_BUFFER_BIT);
    }

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glBindTexture(GL_TEXTURE_2D, 0);
    glFlush();
    return true;
}

// Destroy GL textures and FBOs.
static void destroy_gl_textures(uint32_t* texture_ids, uint32_t* fbo_ids)
{
    for (int i = 0; i < 3; i++)
    {
        if (fbo_ids[i] != 0)
        {
            glDeleteFramebuffers(1, &fbo_ids[i]);
            fbo_ids[i] = 0;
        }
        if (texture_ids[i] != 0)
        {
            glDeleteTextures(1, &texture_ids[i]);
            texture_ids[i] = 0;
        }
    }
}

// Handle method calls from Dart.
static void rive_native_plugin_handle_method_call(RiveNativePlugin* self,
                                                  FlMethodCall* method_call)
{
    g_autoptr(FlMethodResponse) response = nullptr;
    const gchar* method = fl_method_call_get_name(method_call);
    FlValue* args = fl_method_call_get_args(method_call);

    if (strcmp(method, "createTexture") == 0)
    {
        // Ensure the shared GL context is initialized.
        if (!self->shared_gl_context)
        {
            if (!rive_native_plugin_init_shared_context(self))
            {
                response = FL_METHOD_RESPONSE(fl_method_error_response_new(
                    "GL_CONTEXT_ERROR",
                    "Failed to create shared GL context",
                    nullptr));
                fl_method_call_respond(method_call, response, nullptr);
                return;
            }
        }

        // Initialize the Rive renderer context if not done yet.
        if (!self->rive_renderer_context)
        {
            GdkGLContext* initCtx = self->ffi_gl_context
                                        ? self->ffi_gl_context
                                        : self->shared_gl_context;
            gdk_gl_context_make_current(initCtx);
            self->rive_renderer_context = createRiveRendererContext(nullptr);
            if (!self->rive_renderer_context)
            {
                response = FL_METHOD_RESPONSE(fl_method_error_response_new(
                    "RENDERER_ERROR",
                    "Failed to create Rive renderer context",
                    nullptr));
                fl_method_call_respond(method_call, response, nullptr);
                return;
            }
            setLinuxMakeCurrentCallback(on_global_make_current, (void*)initCtx);
        }

        // Parse width and height.
        FlValue* width_val = fl_value_lookup_string(args, "width");
        FlValue* height_val = fl_value_lookup_string(args, "height");
        if (!width_val || !height_val)
        {
            response = FL_METHOD_RESPONSE(fl_method_error_response_new(
                "INVALID_ARGS",
                "Missing width or height in createTexture",
                nullptr));
            fl_method_call_respond(method_call, response, nullptr);
            return;
        }
        int32_t width = (int32_t)fl_value_get_int(width_val);
        int32_t height = (int32_t)fl_value_get_int(height_val);

        // Make context current and create GL textures.
        rive_native_plugin_make_context_current(self);

        auto info = std::make_unique<RiveNativeTextureInfo>();
        info->width = width;
        info->height = height;
        info->texture_registrar =
            fl_plugin_registrar_get_texture_registrar(self->registrar);

        if (!create_gl_textures(width,
                                height,
                                info->gl_texture_ids,
                                info->gl_fbos))
        {
            response = FL_METHOD_RESPONSE(
                fl_method_error_response_new("GL_ERROR",
                                             "Failed to create GL textures",
                                             nullptr));
            fl_method_call_respond(method_call, response, nullptr);
            return;
        }

        // Create FlTextureGL and register with Flutter.
        info->gl_texture = rive_native_gl_texture_new();
        info->gl_texture->ring = &info->ring;
        info->gl_texture->width = (uint32_t)width;
        info->gl_texture->height = (uint32_t)height;
        for (int i = 0; i < 3; i++)
        {
            info->gl_texture->gl_texture_ids[i] = info->gl_texture_ids[i];
        }

        fl_texture_registrar_register_texture(info->texture_registrar,
                                              FL_TEXTURE(info->gl_texture));
        info->texture_id = fl_texture_get_id(FL_TEXTURE(info->gl_texture));

        // Store the FFI GL context for the make-current callback.
        info->shared_gl_context = self->ffi_gl_context
                                      ? self->ffi_gl_context
                                      : self->shared_gl_context;

        // Set up callbacks so native code can make GL context current and
        // notify Flutter when a frame is done.
        info->callbacks.endCallback = on_renderer_end;
        info->callbacks.makeCurrentCallback = on_make_current;
        info->callbacks.userData = info.get();

        // Create the native Rive renderer for this texture.
        // FBOs inside the renderer are created lazily on the first begin()
        // call (FFI thread), not here.
        info->rive_renderer =
            createRiveRenderer(nullptr, // textureRegistry (unused on Linux)
                               self->rive_renderer_context,
                               &info->callbacks,
                               &info->ring,
                               (void*)(uintptr_t)info->gl_texture_ids[0],
                               (void*)(uintptr_t)info->gl_texture_ids[1],
                               (void*)(uintptr_t)info->gl_texture_ids[2],
                               width,
                               height);

        // Release the GL context from the main thread so the rendering
        // thread can acquire it via makeCurrentCallback.
        gdk_gl_context_clear_current();

        int64_t texture_id = info->texture_id;

        // Format the renderer pointer as a hex string for Dart FFI.
        char buff[255];
        snprintf(buff, sizeof(buff), "%p", info->rive_renderer);

        self->textures->emplace(texture_id, std::move(info));

        g_autoptr(FlValue) result = fl_value_new_map();
        fl_value_set_string_take(result,
                                 "textureId",
                                 fl_value_new_int(texture_id));
        fl_value_set_string_take(result, "renderer", fl_value_new_string(buff));
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
    else if (strcmp(method, "getRenderContext") == 0)
    {
        // Ensure context is initialized.
        if (!self->shared_gl_context)
        {
            rive_native_plugin_init_shared_context(self);
        }
        if (!self->rive_renderer_context && self->shared_gl_context)
        {
            GdkGLContext* initCtx = self->ffi_gl_context
                                        ? self->ffi_gl_context
                                        : self->shared_gl_context;
            gdk_gl_context_make_current(initCtx);
            self->rive_renderer_context = createRiveRendererContext(nullptr);
            setLinuxMakeCurrentCallback(on_global_make_current, (void*)initCtx);
            gdk_gl_context_clear_current();
        }

        // Return 'android' as the rendererContext string. This triggers the
        // Dart FFI code to call riveFactory() via FFI (instead of parsing a
        // hex pointer). The riveFactory() call ensures the GL context is
        // current on the Dart UI thread.
        g_autoptr(FlValue) result = fl_value_new_map();
        fl_value_set_string_take(result,
                                 "rendererContext",
                                 fl_value_new_string(self->rive_renderer_context
                                                         ? "android"
                                                         : "0x0"));
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
    else if (strcmp(method, "removeTexture") == 0)
    {
        FlValue* id_val = fl_value_lookup_string(args, "id");
        if (!id_val)
        {
            response = FL_METHOD_RESPONSE(
                fl_method_error_response_new("INVALID_ARGS",
                                             "Missing id in removeTexture",
                                             nullptr));
            fl_method_call_respond(method_call, response, nullptr);
            return;
        }
        int64_t id = fl_value_get_int(id_val);

        auto it = self->textures->find(id);
        if (it != self->textures->end())
        {
            RiveNativeTextureInfo* info = it->second.get();

            if (info->rive_renderer)
            {
                destroyRiveRenderer(info->rive_renderer);
                info->rive_renderer = nullptr;
            }

            fl_texture_registrar_unregister_texture(
                info->texture_registrar,
                FL_TEXTURE(info->gl_texture));
            g_object_unref(info->gl_texture);

            rive_native_plugin_make_context_current(self);
            destroy_gl_textures(info->gl_texture_ids, info->gl_fbos);

            self->textures->erase(it);
        }
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
    else if (strcmp(method, "getPlatformVersion") == 0)
    {
        struct utsname uname_data = {};
        uname(&uname_data);
        g_autofree gchar* version =
            g_strdup_printf("Linux %s", uname_data.version);
        g_autoptr(FlValue) result = fl_value_new_string(version);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
    else
    {
        response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    }

    fl_method_call_respond(method_call, response, nullptr);
}

// Method call callback.
static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data)
{
    RiveNativePlugin* plugin = RIVE_NATIVE_PLUGIN(user_data);
    rive_native_plugin_handle_method_call(plugin, method_call);
}

// Plugin dispose.
static void rive_native_plugin_dispose(GObject* object)
{
    RiveNativePlugin* self = RIVE_NATIVE_PLUGIN(object);

    if (self->textures)
    {
        if (self->shared_gl_context)
        {
            rive_native_plugin_make_context_current(self);
        }
        for (auto& pair : *self->textures)
        {
            RiveNativeTextureInfo* info = pair.second.get();
            if (info->rive_renderer)
            {
                destroyRiveRenderer(info->rive_renderer);
                info->rive_renderer = nullptr;
            }
            if (info->gl_texture)
            {
                fl_texture_registrar_unregister_texture(
                    info->texture_registrar,
                    FL_TEXTURE(info->gl_texture));
                g_object_unref(info->gl_texture);
            }
            destroy_gl_textures(info->gl_texture_ids, info->gl_fbos);
        }
        delete self->textures;
        self->textures = nullptr;
    }

    if (self->rive_renderer_context)
    {
        destroyRiveRendererContext(self->rive_renderer_context);
        self->rive_renderer_context = nullptr;
    }

    if (self->ffi_gl_context)
    {
        g_object_unref(self->ffi_gl_context);
        self->ffi_gl_context = nullptr;
    }
    if (self->shared_gl_context)
    {
        g_object_unref(self->shared_gl_context);
        self->shared_gl_context = nullptr;
    }

    g_clear_object(&self->channel);
    g_clear_object(&self->registrar);

    G_OBJECT_CLASS(rive_native_plugin_parent_class)->dispose(object);
}

static void rive_native_plugin_class_init(RiveNativePluginClass* klass)
{
    G_OBJECT_CLASS(klass)->dispose = rive_native_plugin_dispose;
}

static void rive_native_plugin_init(RiveNativePlugin* self)
{
    self->textures =
        new std::map<int64_t, std::unique_ptr<RiveNativeTextureInfo>>();
    self->shared_gl_context = nullptr;
    self->ffi_gl_context = nullptr;
    self->shared_context_initialized = false;
    self->rive_renderer_context = nullptr;
}

void rive_native_plugin_register_with_registrar(FlPluginRegistrar* registrar)
{
    RiveNativePlugin* plugin = RIVE_NATIVE_PLUGIN(
        g_object_new(rive_native_plugin_get_type(), nullptr));

    plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));

    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    plugin->channel =
        fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                              "rive_native",
                              FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(plugin->channel,
                                              method_call_cb,
                                              g_object_ref(plugin),
                                              g_object_unref);

    g_object_unref(plugin);

    // Force link these methods to pull the whole object file from the static
    // library. Without these calls, the linker may strip unused symbols.
    loadRiveFile(nullptr, 0);
    deleteFlutterRenderer(nullptr);
    rewindRenderPath(nullptr);
    disposeYogaStyle(nullptr);
    riveFontDummyLinker();
#ifdef RIVE_WITH_SCRIPTING
    riveLuaDummyLinker();
#endif
    stopAudioSound(nullptr, 0);
}
