import 'dart:async';
import 'dart:ffi';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:rive_native/platform.dart';
import 'package:flutter/widgets.dart' hide Key;
import 'package:flutter/widgets.dart' as flutter show Key;
import 'package:rive_native/rive_native.dart';
import 'package:rive_native/src/ffi/dynamic_library_helper.dart';
import 'package:rive_native/src/ffi/rive_renderer_ffi.dart';
import 'package:rive_native/src/rive.dart' as rive;

final DynamicLibrary nativeLib = DynamicLibraryHelper.nativeLib;

Set<int> _allTextures = {};
final bool Function(Pointer<Void>, bool, int) _nativeClear = nativeLib
    .lookup<NativeFunction<Bool Function(Pointer<Void>, Bool, Uint32)>>('clear')
    .asFunction();
final bool Function(Pointer<Void>, double) _nativeFlush = nativeLib
    .lookup<NativeFunction<Bool Function(Pointer<Void>, Float)>>('flush')
    .asFunction();
final Pointer<Void> Function(Pointer<Void>) _nativeTexture = nativeLib
    .lookup<NativeFunction<Pointer<Void> Function(Pointer<Void>)>>(
      'nativeTexture',
    )
    .asFunction();

// --- Headless rendering FFI lookups ---
final Pointer<Void> Function(bool) _createHeadlessContext = nativeLib
    .lookup<NativeFunction<Pointer<Void> Function(Bool)>>(
        'createHeadlessContext')
    .asFunction();
final Pointer<Void> Function(Pointer<Void>) _headlessContextFactory = nativeLib
    .lookup<NativeFunction<Pointer<Void> Function(Pointer<Void>)>>(
        'headlessContextFactory')
    .asFunction();
final Pointer<Void> Function(Pointer<Void>, int, int) _createHeadlessRenderer =
    nativeLib
        .lookup<
            NativeFunction<
                Pointer<Void> Function(
                    Pointer<Void>, Uint32, Uint32)>>('createHeadlessRenderer')
        .asFunction();
final bool Function(Pointer<Void>, bool, int) _headlessClear = nativeLib
    .lookup<NativeFunction<Bool Function(Pointer<Void>, Bool, Uint32)>>(
        'headlessClear')
    .asFunction();
final bool Function(Pointer<Void>, double) _headlessFlush = nativeLib
    .lookup<NativeFunction<Bool Function(Pointer<Void>, Float)>>(
        'headlessFlush')
    .asFunction();
final Pointer<Void> Function(Pointer<Void>) _headlessMakeRenderer = nativeLib
    .lookup<NativeFunction<Pointer<Void> Function(Pointer<Void>)>>(
        'headlessMakeRenderer')
    .asFunction();
final bool Function(Pointer<Void>, Pointer<Uint8>) _headlessReadPixels =
    nativeLib
        .lookup<NativeFunction<Bool Function(Pointer<Void>, Pointer<Uint8>)>>(
            'headlessReadPixels')
        .asFunction();
final void Function(Pointer<Void>) _destroyHeadlessRenderer = nativeLib
    .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
        'destroyHeadlessRenderer')
    .asFunction();
final void Function(Pointer<Void>) _destroyHeadlessContext = nativeLib
    .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
        'destroyHeadlessContext')
    .asFunction();

base class _NativeRenderTexture extends RenderTexture {
  @override
  int get textureId => _textureId;

  @override
  Pointer<Void> get nativeTexture => _nativeTexture(_rendererPtr);

  final MethodChannel methodChannel;
  int _textureId = -1;
  Pointer<Void> _rendererPtr = nullptr;

  _NativeRenderTexture(this.methodChannel);

  @override
  bool get isReady => _textureId != -1;

  @override
  void dispose() {
    if (_textureId != -1) {
      _allTextures.remove(_textureId);
      _disposeTexture(_textureId);
      _textureId = -1;
    }
  }

  int _width = 0;
  int _height = 0;
  int _actualWidth = 0;
  int _actualHeight = 0;

  @override
  int get actualWidth => _actualWidth;
  @override
  int get actualHeight => _actualHeight;

  @override
  bool needsResize(int width, int height) =>
      width != _width || height != _height;

  @override
  bool get isDisposed => _textureId == -1;

  final List<int> _deadTextures = [];

  void _disposeTextures() {
    _disposeTimer = null;
    var textures = _deadTextures.toList();
    _deadTextures.clear();
    for (final texture in textures) {
      methodChannel.invokeMethod('removeTexture', {'id': texture});
    }
  }

  Timer? _disposeTimer;
  void _disposeTexture(int id) {
    _deadTextures.add(id);
    if (_disposeTimer != null) {
      return;
    }

    _disposeTimer = Timer(const Duration(seconds: 1), _disposeTextures);
  }

  @override
  Future<void> makeRenderTexture(int width, int height) async {
    assert(width >= 0 && height >= 0,
        'Rive render texture width and height must be greater than or equal to 0. Width: $width, Height: $height');
    // Immediately update cached values in-case we redraw during udpate.
    _width = width;
    _height = height;
    final result = await methodChannel.invokeMethod('createTexture', {
      'width': width == 0 ? 1 : width,
      'height': height == 0 ? 1 : height,
    });
    _actualWidth = width;
    _actualHeight = height;
    int? textureId = result['textureId'] as int?;
    String renderer = result['renderer'] as String;
    _rendererPtr = Pointer<Void>.fromAddress(
        int.parse(renderer.substring(renderer.indexOf('x') + 1), radix: 16));

    if (textureId != null) {
      _allTextures.add(textureId);
    }
    if (_textureId != -1) {
      _allTextures.remove(_textureId);
      _disposeTexture(_textureId);
    }

    if (textureId == null) {
      _textureId = -1;
    } else {
      _textureId = textureId;
    }
  }

  @override
  Widget widget({RenderTexturePainter? painter, flutter.Key? key}) =>
      _RiveNativeView(this, painter, key: key);

  void _markDestroyed() {
    _rendererPtr = nullptr;
    final textureIdToDestroy = _textureId;
    if (textureIdToDestroy != -1) {
      _textureId = -1;
      _allTextures.remove(textureIdToDestroy);
      _disposeTexture(textureIdToDestroy);
      _width = _height = 0;
    }
  }

  @override
  bool clear(Color color, [bool write = true]) {
    // ignore: deprecated_member_use
    if (!_nativeClear(_rendererPtr, write, color.value)) {
      _markDestroyed();
      return false;
    }
    return true;
  }

  @override
  bool flush(double devicePixelRatio) {
    if (!_nativeFlush(_rendererPtr, devicePixelRatio)) {
      _markDestroyed();
      return false;
    }
    return true;
  }

  @override
  Renderer get renderer => FFIRiveRenderer(rive.Factory.rive, _rendererPtr);

  @override
  Future<ui.Image> toImage() {
    final scene = ui.SceneBuilder();
    scene.addTexture(
      _textureId,
      width: _width.toDouble(),
      height: _height.toDouble(),
      freeze: true,
    );

    final build = scene.build();
    return build.toImage(_width, _height);
  }
}

/// A headless render texture for test environments. Uses FFI-based headless
/// Metal rendering instead of Flutter's method channels/texture registry.
base class _HeadlessRenderTexture extends RenderTexture {
  final Pointer<Void> _headlessContext;
  Pointer<Void> _rendererPtr = nullptr;
  int _width = 0;
  int _height = 0;

  _HeadlessRenderTexture(this._headlessContext);

  @override
  int get textureId => -1; // Not used in headless mode.

  @override
  dynamic get nativeTexture => nullptr;

  @override
  bool get isReady => _rendererPtr != nullptr;

  @override
  bool get isDisposed => _rendererPtr == nullptr;

  @override
  int get actualWidth => _width;

  @override
  int get actualHeight => _height;

  @override
  bool needsResize(int width, int height) =>
      width != _width || height != _height;

  @override
  Future<void> makeRenderTexture(int width, int height) async {
    if (_rendererPtr != nullptr) {
      _destroyHeadlessRenderer(_rendererPtr);
    }
    _width = width;
    _height = height;
    _rendererPtr = _createHeadlessRenderer(
      _headlessContext,
      width == 0 ? 1 : width,
      height == 0 ? 1 : height,
    );
  }

  @override
  bool clear(Color color, [bool write = true]) {
    if (_rendererPtr == nullptr) return false;
    // ignore: deprecated_member_use
    return _headlessClear(_rendererPtr, write, color.value);
  }

  @override
  bool flush(double devicePixelRatio) {
    if (_rendererPtr == nullptr) return false;
    return _headlessFlush(_rendererPtr, devicePixelRatio);
  }

  @override
  Renderer get renderer {
    final ptr = _headlessMakeRenderer(_rendererPtr);
    return FFIRiveRenderer.fromPointer(ptr, rive.Factory.rive);
  }

  @override
  Future<ui.Image> toImage() async {
    if (_rendererPtr == nullptr || _width == 0 || _height == 0) {
      throw StateError('Headless texture not ready for toImage()');
    }
    final bufferSize = _width * _height * 4;
    final pixelBuffer = malloc.allocate<Uint8>(bufferSize);
    try {
      final success = _headlessReadPixels(_rendererPtr, pixelBuffer);
      if (!success) {
        throw StateError('Failed to read pixels from headless renderer');
      }
      // The C++ side already converts BGRA→RGBA.
      final pixels = Uint8List.fromList(pixelBuffer.asTypedList(bufferSize));
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixels,
        _width,
        _height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return completer.future;
    } finally {
      malloc.free(pixelBuffer);
    }
  }

  @override
  Widget widget({RenderTexturePainter? painter, flutter.Key? key}) {
    throw UnsupportedError('Headless texture does not support widgets');
  }

  @override
  void dispose() {
    if (_rendererPtr != nullptr) {
      _destroyHeadlessRenderer(_rendererPtr);
      _rendererPtr = nullptr;
    }
  }
}

class _RiveNativeFFI extends RiveNative {
  final methodChannel = const MethodChannel('rive_native');
  Pointer<Void> _headlessContext = nullptr;

  @override
  RenderTexture makeRenderTexture() {
    if (Platform.instance.isTesting && _headlessContext != nullptr) {
      return _HeadlessRenderTexture(_headlessContext);
    }
    return _NativeRenderTexture(methodChannel);
  }

  Future<void> initialize() async {
    if (Platform.instance.isTesting) {
      // Headless Metal rendering is only available on Apple platforms and
      // only when the native lib was built with the headless symbols
      // (e.g. lottie_to_rive's shared lib). The regular rive_native dylib
      // does not include them.
      if (!io.Platform.isMacOS && !io.Platform.isIOS) {
        return;
      }
      if (!nativeLib.providesSymbol('createHeadlessContext')) {
        return;
      }
      // Create a headless Metal render context for test mode so that
      // Factory.rive is available without the Flutter platform plugin.
      // Force atomic mode so rendering is deterministic across GPUs.
      _headlessContext = _createHeadlessContext(true);
      if (_headlessContext != nullptr) {
        final factoryPtr = _headlessContextFactory(_headlessContext);
        if (factoryPtr != nullptr) {
          (rive.Factory.rive as FFIRiveFactory).pointer = factoryPtr;
        }
      }
      return;
    }
    try {
      final result = await methodChannel.invokeMethod('getRenderContext', {});

      String rendererContext = result['rendererContext'] as String;
      if (rendererContext == 'android') {
        // on android we grab the global riveFactory.
        final Pointer<Void> Function() riveFactory = nativeLib
            .lookup<NativeFunction<Pointer<Void> Function()>>(
              'riveFactory',
            )
            .asFunction();
        (rive.Factory.rive as FFIRiveFactory).pointer = riveFactory();
      } else {
        (rive.Factory.rive as FFIRiveFactory).pointer =
            Pointer<Void>.fromAddress(int.parse(
                rendererContext.substring(rendererContext.indexOf('x') + 1),
                radix: 16));
      }
    } catch (e) {
      var message = '''
Error creating Rive Native render context
It could be because the native library is not loaded.

Try running the following command to fix this issue:
`dart run rive_native:setup --verbose --clean --platform <platform>`

Error: $e
''';
      debugPrint(message);
      rethrow;
    }
  }
}

Future<RiveNative?> makeRiveNative() async {
  WidgetsFlutterBinding.ensureInitialized();
  final riveNative = _RiveNativeFFI();
  await riveNative.initialize();
  return riveNative;
}

class _RiveNativeView extends LeafRenderObjectWidget {
  final _NativeRenderTexture renderTexture;
  final RenderTexturePainter? painter;
  const _RiveNativeView(this.renderTexture, this.painter, {super.key});

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RiveNativeViewRenderObject(renderTexture, painter)
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context)
      ..tickerModeEnabled = TickerMode.of(context);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RiveNativeViewRenderObject renderObject,
  ) {
    renderObject
      ..renderTexture = renderTexture
      ..painter = painter
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context)
      ..tickerModeEnabled = TickerMode.of(context);
  }

  @override
  void didUnmountRenderObject(
    covariant _RiveNativeViewRenderObject renderObject,
  ) {
    renderObject.painter = null;
  }
}

class _RiveNativeViewRenderObject extends RiveNativeRenderBox
    with WidgetsBindingObserver {
  _RiveNativeViewRenderObject(
    super._renderTexture,
    RenderTexturePainter? renderTexturePainter,
  ) {
    painter = renderTexturePainter;

    // Add an observer to monitor the widget lifecycle changes
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      restartTickerIfStopped();
      markNeedsLayout();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  ui.Size get desiredSize => ui.Size(
        renderTexture.actualWidth.toDouble() / scaleWidth,
        renderTexture.actualHeight.toDouble() / scaleHeight,
      );

  bool _isCreatingTexture = false;
  bool _markNeedsTextureCreation = false;

  @override
  void performLayout() {
    super.performLayout();
    if (owner == null || !attached) {
      return;
    }

    // If we're busy creating the texture, we mark it as needing to be created
    // again, and exit early to avoid unnecessary texture creation while resizing.
    if (_isCreatingTexture) {
      _markNeedsTextureCreation = true;
      return;
    }

    final width =
        (size.width * devicePixelRatio * desiredTransformWidthScale).round();
    final height =
        (size.height * devicePixelRatio * desiredTransformHeightScale).round();

    if (renderTexture.needsResize(width, height) || renderTexture.isDisposed) {
      _isCreatingTexture = true;
      renderTexture.makeRenderTexture(width, height).then((_) {
        // Check if the render object is still attached and not disposed
        if (!attached) {
          return;
        }
        rivePainter?.textureChanged();
        renderTexture.textureChanged();

        // Texture id will have changed...
        markNeedsPaint();

        // A new layout was requested while the texture was being created
        // so we need to create the latest.
        if (_markNeedsTextureCreation) {
          markNeedsLayout();
        }
        _isCreatingTexture = false;
        _markNeedsTextureCreation = false;
      }).onError((error, stackTrace) {
        debugPrint('$error $stackTrace');
        _isCreatingTexture = false;
        _markNeedsTextureCreation = false;
      });
    }
  }

  @override
  ui.Size computeDryLayout(BoxConstraints constraints) => constraints.smallest;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);

    if (!renderTexture.isReady) {
      return;
    }
    context.addLayer(
      TextureLayer(
        rect: Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
        textureId: renderTexture.textureId,
        filterQuality: FilterQuality.low,
      ),
    );

    final painter = rivePainter;
    if (painter != null && painter.paintsCanvas) {
      painter.paintCanvas(context.canvas, offset, size);
    }
  }
}
