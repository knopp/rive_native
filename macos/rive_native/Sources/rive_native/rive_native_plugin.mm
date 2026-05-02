#import "rive_native_plugin.h"
#include "rive_native/external.hpp"
#include "rive_native/external_objc.h"
#include "rive_native/read_write_ring.hpp"
#import <MetalKit/MetalKit.h>

// rive_binding wants this defined
bool usePLS = true;

// Forward declaration for linker dummy function
void linkDummyMethods();

#pragma mark - RiveNativeRenderTexture

@interface RiveNativeRenderTexture ()
{
    CVMetalTextureCacheRef _metalTextureCache;
    CVMetalTextureRef _metalTextureCVRef;
@public
    id<MTLTexture> _metalTexture;
@public
    MTLRenderPassDescriptor* _passDescriptor;
    CVPixelBufferRef _pixelData;

    std::mutex _mutex;
    id<MTLEvent> _event;
    int64_t _eventValue;
    int64_t _eventToSignalInPreCommit;

    // Rive/C++ interop
    void* _riveRenderer;
}
@end

@implementation RiveNativeRenderTexture
- (instancetype)initWithDevice:(id<MTLDevice>)device
                    andContext:(void*)context
                      andQueue:(id<MTLCommandQueue>)commandQueue
                      andWidth:(int)width
                     andHeight:(int)height
                  registerWith:(NSObject<FlutterTextureRegistry>*)registry
{
    self = [super init];
    _riveRenderer = nullptr;
    if (self)
    {
        _width = width;
        _height = height;
        NSDictionary* options = @{
            // This key is required to generate SKPicture with CVPixelBufferRef
            // in metal.
            (NSString*)kCVPixelBufferMetalCompatibilityKey : @YES
        };
        CVReturn status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &_metalTextureCache);
        if (status != kCVReturnSuccess)
        {
            NSLog(@"CVMetalTextureCacheCreate error %d", (int)status);
        }
        status = CVPixelBufferCreate(kCFAllocatorDefault,
                                     width,
                                     height,
                                     kCVPixelFormatType_32BGRA,
                                     (__bridge CFDictionaryRef)options,
                                     &_pixelData);
        if (status != kCVReturnSuccess)
        {
            NSLog(@"CVPixelBufferCreate error %d", (int)status);
        }

        status =
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                      _metalTextureCache,
                                                      _pixelData,
                                                      nil,
                                                      MTLPixelFormatBGRA8Unorm,
                                                      width,
                                                      height,
                                                      0,
                                                      &_metalTextureCVRef);
        if (status != kCVReturnSuccess)
        {
            NSLog(@"CVMetalTextureCacheCreateTextureFromImage error %d",
                  (int)status);
        }
        _metalTexture = CVMetalTextureGetTexture(_metalTextureCVRef);
        // make 3 of these...
        _passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        _passDescriptor.colorAttachments[0].texture = _metalTexture;
        _passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        _passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        _passDescriptor.colorAttachments[0].clearColor =
            MTLClearColorMake(0.0, 0.0, 0.0, 0.0);

        _event = [device newEvent];
        _eventValue = 0;
        _eventToSignalInPreCommit = 0;

        // Register with Flutter
        _flutterTextureId = [registry registerTexture:self];

        // --- Ownership boundary: pass retained pointers into C++ ---
        // These are used asynchronously by the renderer callbacks.
        // We transfer an extra retain into "CF/void* world" here.
        // The C++ side MUST CFRelease them.

        void* registry_retained = (__bridge_retained void*)registry;
        void* self_retained = (__bridge_retained void*)self;
        void* queue_bridged = (__bridge void*)commandQueue;
        void* tex_bridged = (__bridge void*)_metalTexture;

        _riveRenderer = createRiveRenderer(
            registry_retained,
            context, // already a C pointer owned by C++ context
            self_retained,
            queue_bridged,
            tex_bridged,
            width,
            height);
        // NOTE: Do NOT CFRelease any of the *_retained pointers here.
        // Ownership is now shared between C++ and Obj-C
    }

    return self;
}

- (int64_t)flutterTextureId
{
    return _flutterTextureId;
}

// Explicitly break the C++ <-> Obj-C ownership by destroying the C++ renderer.
- (void)destroyRenderer
{
    riveLock();
    void* renderer = _riveRenderer;
    _riveRenderer = nullptr;
    if (renderer)
    {
        destroyRiveRenderer(renderer);
    }
    riveUnlock();
}

- (void)dealloc
{
    // Invalidate C++ renderer (it should stop scheduling callbacks once
    // destroyed)
    [self destroyRenderer];

    // Release CV/Metal resources
    _passDescriptor = nil;
    _metalTexture = nil;
    if (_metalTextureCVRef)
    {
        CFRelease(_metalTextureCVRef);
        _metalTextureCVRef = nil;
    }
    if (_pixelData)
    {
        CVPixelBufferRelease(_pixelData);
        _pixelData = nil;
    }

    if (_metalTextureCache)
    {
        CFRelease(_metalTextureCache);
        _metalTextureCache = nil;
    }
}

#pragma mark - FlutterTexture

- (CVPixelBufferRef)copyPixelBuffer
{
    CVPixelBufferRef data = _pixelData;
    CVBufferRetain(data);
    return data;
}

- (id<MTLEvent>)copyEventWithValue:(uint64_t*)value
{
    std::lock_guard<std::mutex> lock(_mutex);
    *value = _eventValue;
    // The event will be signalled when Flutter is done with the texture.
    // This is the value Rive will wait for before next render.
    _eventValue += 1;
    return _event;
}

@end

#pragma mark - RiveNativePlugin

@interface RiveNativePlugin ()
{
    id<MTLDevice> _metalDevice;
    id<MTLCommandQueue> _metalCommandQueue;
    void* _riveRendererContext; // owned by C++ context
}
@property(nonatomic, strong) NSObject<FlutterTextureRegistry>* textureRegistry;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber*, RiveNativeRenderTexture*>* renderTextures;
@end

@implementation RiveNativePlugin

static RiveNativePlugin* _instance;

- (instancetype)initWithTextures:(NSObject<FlutterTextureRegistry>*)textures
{
    self = [super init];
    if (self)
    {
        _textureRegistry = textures;
        _renderTextures = [[NSMutableDictionary alloc] init];

        _metalDevice = MTLCreateSystemDefaultDevice();
        _metalCommandQueue = [_metalDevice newCommandQueue];

        // Pass device into C++ context. It will be used across frames.
        // Since the context stores/uses the device asynchronously, bridge as
        // retained. C++ must CFRelease in destroyRiveRendererContext(...).
        void* device_retained = (__bridge_retained void*)_metalDevice;
        _riveRendererContext = createRiveRendererContext(device_retained);

        setGPU((__bridge void*)_metalDevice,
               (__bridge void*)_metalCommandQueue);

        _instance = self;
    }
    return self;
}

- (void)dealloc
{
    riveLock();
    if (_riveRendererContext != nullptr)
    {
        destroyRiveRendererContext(_riveRendererContext);
        _riveRendererContext = nullptr;
    }
    // Clear global GPU pointers to avoid stale globals after teardown.
    setGPU(nullptr, nullptr);
    riveUnlock();

    // Explicitly release Metal resources in the correct order (queue before
    // device) to prevent the compiler-generated .cxx_destruct from releasing
    // them in declaration order (device first), which causes a use-after-free
    // in MTLResourceListPool when the queue's dealloc calls _purgeDevice on
    // an already-torn-down device.
    // https://github.com/rive-app/rive-flutter/issues/623
    _metalCommandQueue = nil;
    _metalDevice = nil;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar
{
    FlutterMethodChannel* channel =
        [FlutterMethodChannel methodChannelWithName:@"rive_native"
                                    binaryMessenger:[registrar messenger]];

    auto riveNativePluginInstance =
        [[RiveNativePlugin alloc] initWithTextures:[registrar textures]];
    [registrar addMethodCallDelegate:riveNativePluginInstance channel:channel];

    linkDummyMethods();
}

#pragma mark - C callback into Obj-C (used by C++)

void preFlushCallback(id<MTLCommandBuffer> commandBuffer,
                      void* nativeRenderTexture)
{
    // Encode wait before rendering to make sure that Flutter is done
    // with the texture.
    auto rt = (__bridge RiveNativeRenderTexture*)nativeRenderTexture;
    std::lock_guard<std::mutex> lock(rt->_mutex);
    [commandBuffer encodeWaitForEvent:rt->_event value:rt->_eventValue];
    ++rt->_eventValue;
    rt->_eventToSignalInPreCommit = rt->_eventValue;
}

void preCommitCallback(id<MTLCommandBuffer> commandBuffer,
                       void* nativeRenderTexture,
                       void* renderer,
                       void* textureRegistry)
{
    // Retain the bridged CF pointers for the duration of the completion
    // handler to guarantee lifetime across async boundary.

    auto rt = (__bridge RiveNativeRenderTexture*)nativeRenderTexture;

    // signal the event to unblock Flutter
    [commandBuffer encodeSignalEvent:rt->_event
                               value:rt->_eventToSignalInPreCommit];
}

#pragma mark - Flutter plugin API

- (void)createTextureWithWidth:(int64_t)width
                        height:(int64_t)height
                  textureIdOut:(int64_t*)textureIdOut
                   rendererOut:(int64_t*)rendererOut
{
    RiveNativeRenderTexture* renderTexture =
        [[RiveNativeRenderTexture alloc] initWithDevice:_metalDevice
                                             andContext:_riveRendererContext
                                               andQueue:_metalCommandQueue
                                               andWidth:(int)width
                                              andHeight:(int)height
                                           registerWith:_textureRegistry];

    // Store strongly so lifetime outlives async GPU callbacks.
    _renderTextures[@(renderTexture.flutterTextureId)] = renderTexture;

    *textureIdOut = renderTexture.flutterTextureId;
    *rendererOut = (int64_t)renderTexture->_riveRenderer;
}

- (void)removeTextureWithId:(int64_t)textureId
{
    RiveNativeRenderTexture* texture = _renderTextures[@(textureId)];
    if (texture)
    {
        // Break C++/Obj-C ownership before unregistering to avoid retain
        // cycles and to ensure command buffer callbacks won't outlive
        // the texture wrapper.
        [texture destroyRenderer];
        // Unregister first so Flutter stops asking for frames.
        [_textureRegistry unregisterTexture:texture.flutterTextureId];

        // Drop strong ref -> triggers -dealloc, which destroys the C++
        // renderer and (on the C++ side) CFReleases the retained bridged
        // pointers.
        [_renderTextures removeObjectForKey:@(textureId)];
    }
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result
{
    if ([call.method isEqualToString:@"getRenderContext"])
    {
        char buff[255];
        snprintf(buff,
                 sizeof(buff),
                 "%p",
                 factoryFromRiveRendererContext(_riveRendererContext));

        result(@{
            @"rendererContext" :
                [NSString stringWithCString:buff encoding:NSUTF8StringEncoding]
        });
        return;
    }

    result(FlutterMethodNotImplemented);
}
@end

#pragma mark - Link dummy methods

extern "C" void createTexture(int width,
                              int height,
                              int64_t* textureIdOut,
                              int64_t* rendererOut)
{
    if (_instance)
    {
        [_instance createTextureWithWidth:width
                                   height:height
                             textureIdOut:textureIdOut
                              rendererOut:rendererOut];
    }
}

extern "C" void removeTexture(int64_t textureId)
{
    if (_instance)
    {
        [_instance removeTextureWithId:textureId];
    }
}

// Forward declarations for FFI functions that need force-linking.
// These are accessed via dlsym at runtime, so we reference them here
// to prevent the linker from stripping them from the static library.
extern "C"
{
    void* loadRiveFile(const void*, size_t, void*, void*);
    void deleteFlutterRenderer(void*);
    void rewindRenderPath(void*);
    void disposeYogaStyle(void*);
    void riveFontDummyLinker();
    void stopAudioSound(void*, uint64_t);
}

void linkDummyMethods()
{
    loadRiveFile(nullptr, 0, nullptr, nullptr);
    deleteFlutterRenderer(nullptr);
    rewindRenderPath(nullptr);
    disposeYogaStyle(nullptr);
    riveFontDummyLinker();
    stopAudioSound(nullptr, 0);
}