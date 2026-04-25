import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Animation;
import 'package:meta/meta.dart';
import 'package:rive_native/rive_native.dart';
import 'package:rive_native/semantics.dart';
import 'package:rive_native/src/rive.dart' show RiveProfiler;

abstract base class ProceduralPainter extends RivePainter {
  /// Called each frame to advance the animation.
  bool advance(double elapsedSeconds);

  /// Called each frame to paint the artboard.
  void paint(Renderer renderer, Size size, double paintPixelRatio);

  /// Request a repaint of the artboard.
  void scheduleRepaint() => notifyListeners();
}

abstract base class ArtboardPainter extends ProceduralPainter {
  /// Called when the underlying artboard changes.
  void artboardChanged(Artboard artboard);
}

base class BasicArtboardPainter extends ArtboardPainter
    with RiveTickerAwarePainterMixin, RiveArtboardLayoutMixin {
  BasicArtboardPainter({
    Fit fit = RiveDefaults.fit,
    Alignment alignment = RiveDefaults.alignment,
    double layoutScaleFactor = RiveDefaults.layoutScaleFactor,
  }) {
    this.fit = fit;
    this.alignment = alignment;
    this.layoutScaleFactor = layoutScaleFactor;
  }

  Artboard? _artboard;
  @override
  Artboard? get artboard => _artboard;

  @mustCallSuper
  @override
  void artboardChanged(Artboard artboard) {
    _artboard = artboard;
  }

  @override
  bool advance(double elapsedSeconds) {
    bool advanced = _artboard?.advance(elapsedSeconds) ?? false;
    return advanced || (_artboard?.updatePass() ?? false);
  }

  @mustCallSuper
  @override
  void paint(Renderer renderer, Size size, double paintPixelRatio) {
    final artboard = _artboard;
    if (artboard == null) {
      return;
    }
    renderer.align(
      fit,
      alignment,
      AABB.fromValues(0, 0, size.width, size.height),
      artboard.bounds,
      layoutScaleFactor,
    );
    artboard.draw(renderer);
  }
}

base class SingleAnimationPainter extends BasicArtboardPainter {
  final String animationName;
  Animation? _animation;
  SingleAnimationPainter(this.animationName, {super.fit, super.alignment});

  @override
  void artboardChanged(Artboard artboard) {
    super.artboardChanged(artboard);
    _animation = artboard.animationNamed(animationName);
    notifyListeners();
  }

  @override
  bool advance(double elapsedSeconds) {
    return _animation?.advanceAndApply(elapsedSeconds) ?? false;
  }
}

base class StateMachinePainter extends BasicArtboardPainter
    with RivePointerEventMixin, RiveSemanticsMixin {
  final String? stateMachineName;
  StateMachine? _stateMachine;
  StateMachine? get stateMachine => _stateMachine;
  CallbackHandler? _inputCallbackHandler;

  StateMachinePainter({
    this.stateMachineName,
    this.withStateMachine,
    super.fit,
    super.alignment,
    RiveHitTestBehavior hitTestBehavior = RiveDefaults.hitTestBehaviour,
    MouseCursor cursor = RiveDefaults.mouseCursor,
  }) {
    this.cursor = cursor;
    this.hitTestBehavior = hitTestBehavior;
  }

  final void Function(StateMachine)? withStateMachine;

  @override
  StateMachine? get semanticsStateMachine => _stateMachine;

  @override
  void artboardChanged(Artboard artboard) {
    super.artboardChanged(artboard);
    _stateMachine?.dispose();
    final machine = _stateMachine = stateMachineName != null
        ? artboard.stateMachine(stateMachineName!)
        : artboard.defaultStateMachine();
    if (machine != null) {
      if (isSemanticsEnabled) {
        machine.enableSemantics();
      }
      _inputCallbackHandler = machine.onInputChanged(_onInputChanged);
      withStateMachine?.call(machine);
    }
    notifyListeners();
  }

  void _onInputChanged(int inputId) => notifyListeners();

  @override
  bool hitTest(Offset position) {
    final artboard = _artboard;
    if (artboard == null) {
      return false;
    }
    final value = stateMachine?.hitTest(
          localToArtboard(
            position: position,
            artboardBounds: artboard.bounds,
            fit: fit,
            alignment: alignment,
            size: size,
            scaleFactor: layoutScaleFactor,
          ),
        ) ??
        false;
    return value;
  }

  @override
  void pointerEvent(PointerEvent event, HitTestEntry<HitTestTarget> entry) {
    final stateMachine = _stateMachine;
    final artboard = _artboard;
    if (stateMachine == null || artboard == null) return;

    final position = localToArtboard(
      position: event.localPosition,
      artboardBounds: artboard.bounds,
      fit: fit,
      alignment: alignment,
      size: size,
      scaleFactor: layoutScaleFactor,
    );

    if (event is PointerDownEvent) {
      stateMachine.pointerDown(position, pointerId: event.pointer);
    } else if (event is PointerUpEvent) {
      stateMachine.pointerUp(position, pointerId: event.pointer);
    } else if (event is PointerMoveEvent) {
      stateMachine.pointerMove(position, pointerId: event.pointer);
    } else if (event is PointerHoverEvent) {
      stateMachine.pointerMove(position, pointerId: event.pointer);
    } else if (event is PointerExitEvent) {
      stateMachine.pointerExit(position, pointerId: event.pointer);
    }
  }

  @override
  bool advance(double elapsedSeconds) {
    final advanced = _stateMachine?.advanceAndApply(elapsedSeconds) ?? false;
    updateSemantics();
    return advanced;
  }

  @override
  void dispose() {
    _stateMachine?.dispose();
    _stateMachine = null;
    _inputCallbackHandler?.dispose();
    _inputCallbackHandler = null;
    disposeSemantics();
    super.dispose();
  }
}

class RiveFileWidget extends StatefulWidget {
  final File file;
  final ArtboardPainter painter;
  final String? artboardName;

  const RiveFileWidget({
    required this.file,
    required this.painter,
    this.artboardName,
    super.key,
  });

  @override
  State<RiveFileWidget> createState() => _RiveFileWidgetState();
}

class _RiveFileWidgetState extends State<RiveFileWidget> {
  Artboard? _artboard;
  @override
  void initState() {
    _initArtboard();
    super.initState();
  }

  void _initArtboard() {
    var name = widget.artboardName;
    _artboard = name == null
        ? widget.file.defaultArtboard()
        : widget.file.artboard(name);
  }

  @override
  void dispose() {
    _artboard = null;

    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RiveFileWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file != widget.file ||
        oldWidget.artboardName != widget.artboardName ||
        oldWidget.painter != widget.painter) {
      setState(() {
        _initArtboard();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final artboard = _artboard;
    if (artboard == null) {
      return ErrorWidget.withDetails(
        message: 'Unable to load Rive artboard: "${widget.artboardName}"',
        error: FlutterError('Unable to load artboard: ${widget.artboardName}'),
      );
    }
    return RiveArtboardWidget(
      artboard: artboard,
      painter: widget.painter,
    );
  }
}

class RiveArtboardWidget extends StatefulWidget {
  final Artboard artboard;
  final ArtboardPainter painter;

  const RiveArtboardWidget({
    required this.artboard,
    required this.painter,
    super.key,
  });

  @override
  State<RiveArtboardWidget> createState() => _RiveArtboardWidgetState();
}

class _RiveArtboardWidgetState extends State<RiveArtboardWidget> {
  @override
  void initState() {
    super.initState();
    widget.painter.artboardChanged(widget.artboard);
  }

  @override
  void didUpdateWidget(covariant RiveArtboardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artboard != widget.artboard) {
      widget.painter.artboardChanged(widget.artboard);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.artboard.riveFactory == Factory.flutter) {
      return FlutterRiveRendererWidget(painter: widget.painter);
    }
    return ArtboardWidgetRiveRenderer(painter: widget.painter);
  }
}

/// Widget that adds a semantic accessibility overlay to a Rive artboard.
///
/// Wrap a [RiveArtboardWidget] with this to enable screen reader support.
/// The overlay reads the semantic tree from the painter and projects it
/// as Flutter [SemanticsNode]s aligned with the artboard's visual elements.
///
/// ```dart
/// RiveSemanticsWidget(
///   artboard: artboard,
///   painter: painter,
///   child: RiveArtboardWidget(artboard: artboard, painter: painter),
/// )
/// ```
@experimental
@internal
class RiveSemanticsWidget extends StatefulWidget {
  final Artboard artboard;
  final ArtboardPainter painter;
  final Widget child;

  const RiveSemanticsWidget({
    required this.artboard,
    required this.painter,
    required this.child,
    super.key,
  });

  @override
  State<RiveSemanticsWidget> createState() => _RiveSemanticsWidgetState();
}

class _RiveSemanticsWidgetState extends State<RiveSemanticsWidget> {
  @override
  void initState() {
    super.initState();
    final sem = _semanticsMixin;
    if (sem != null) {
      _enableSemantics(sem, widget.painter);
    }
  }

  RiveSemanticsMixin? get _semanticsMixin {
    final painter = widget.painter;
    return painter is RiveSemanticsMixin ? painter as RiveSemanticsMixin : null;
  }

  void _enableSemantics(RiveSemanticsMixin sem, ArtboardPainter painter) {
    sem.semanticsEnabled = true;
    // Prime one zero-delta advance so world transforms/text layout are
    // valid before the first semantics snapshot.
    painter.advance(0);
    sem.semanticTree?.addListener(_onSemanticUpdate);
  }

  // Disabling disposes the SemanticTreeModel on the mixin (see
  // RiveSemanticsMixin.semanticsEnabled setter), so a later re-enable
  // always starts from an empty tree — no risk of applying a fresh diff
  // stream onto nodes from a different artboard.
  void _disableSemantics(RiveSemanticsMixin sem) {
    sem.semanticTree?.removeListener(_onSemanticUpdate);
    sem.semanticsEnabled = false;
  }

  void _onSemanticUpdate() {
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant RiveSemanticsWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artboard == widget.artboard &&
        oldWidget.painter == widget.painter) {
      return;
    }
    final oldPainter = oldWidget.painter;
    if (oldPainter is RiveSemanticsMixin) {
      _disableSemantics(oldPainter as RiveSemanticsMixin);
    }
    final sem = _semanticsMixin;
    if (sem != null) {
      _enableSemantics(sem, widget.painter);
    }
  }

  @override
  void dispose() {
    final sem = _semanticsMixin;
    if (sem != null) {
      _disableSemantics(sem);
    }
    super.dispose();
  }

  StateMachine? get _stateMachine =>
      _semanticsMixin?.semanticsStateMachine;

  void _handleSemanticFocus(int semanticNodeId) {
    _stateMachine?.focusSemanticNode(semanticNodeId);
  }

  void _handleSemanticTap(SemanticNodeData data) {
    _stateMachine?.fireSemanticAction(data.id, SemanticActionType.tap);
  }

  void _handleSemanticIncrease(SemanticNodeData data) {
    _stateMachine?.fireSemanticAction(data.id, SemanticActionType.increase);
  }

  void _handleSemanticDecrease(SemanticNodeData data) {
    _stateMachine?.fireSemanticAction(data.id, SemanticActionType.decrease);
  }

  @override
  Widget build(BuildContext context) {
    final tree = _semanticsMixin?.semanticTree;
    final bounds = widget.artboard.worldBounds;
    if (tree == null) {
      return widget.child;
    }

    final painter = widget.painter;
    final layout = painter is RiveArtboardLayoutMixin
        ? painter as RiveArtboardLayoutMixin
        : null;
    final fit = layout?.fit ?? Fit.contain;
    final align = layout?.alignment ?? Alignment.center;
    final scale = layout?.layoutScaleFactor ?? 1.0;

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned.fill(
          child: RiveSemanticsOverlay(
            tree: tree,
            artboardBounds: bounds,
            fit: fit,
            alignment: align,
            layoutScaleFactor: scale,
            onSemanticTap: _handleSemanticTap,
            onSemanticFocus: _handleSemanticFocus,
            onSemanticIncrease: _handleSemanticIncrease,
            onSemanticDecrease: _handleSemanticDecrease,
          ),
        ),
      ],
    );
  }
}

class RiveProceduralRenderingWidget extends StatefulWidget {
  final Factory riveFactory;
  final ProceduralPainter painter;

  const RiveProceduralRenderingWidget({
    required this.riveFactory,
    required this.painter,
    super.key,
  });

  @override
  State<RiveProceduralRenderingWidget> createState() =>
      _RiveRiveProceduralRenderingWidgetState();
}

class _RiveRiveProceduralRenderingWidgetState
    extends State<RiveProceduralRenderingWidget> {
  @override
  Widget build(BuildContext context) {
    if (widget.riveFactory == Factory.flutter) {
      // Render the artboard with the Flutter renderer.
      return FlutterRiveRendererWidget(painter: widget.painter);
    } else {
      // Render the artboard with the Rive Renderer.
      return ArtboardWidgetRiveRenderer(painter: widget.painter);
    }
  }
}

class ArtboardWidgetRiveRenderer extends StatefulWidget {
  final ProceduralPainter? painter;

  const ArtboardWidgetRiveRenderer({super.key, this.painter});

  @override
  State<ArtboardWidgetRiveRenderer> createState() =>
      _ArtboardWidgetRiveRendererState();
}

base class ArtboardWidgetPainter<T extends ProceduralPainter>
    extends RenderTexturePainter
    with
        RivePointerEventMixin,
        RiveTickerAwarePainterMixin,
        RiveArtboardLayoutMixin {
  final T? _painter;
  T? get painter => _painter;
  final RivePointerEventMixin? _pointerEvent;
  final RiveTickerAwarePainterMixin? _tickerAwarePainter;
  final RiveArtboardLayoutMixin? _riveArtboardLayoutMixin;
  ArtboardWidgetPainter(this._painter)
      : _pointerEvent = _painter is RivePointerEventMixin
            ? _painter as RivePointerEventMixin
            : null,
        _tickerAwarePainter = _painter is RiveTickerAwarePainterMixin
            ? _painter as RiveTickerAwarePainterMixin
            : null,
        _riveArtboardLayoutMixin = _painter is RiveArtboardLayoutMixin
            ? _painter as RiveArtboardLayoutMixin
            : null {
    _painter?.addListener(notifyListeners);
    _tickerAwarePainter?.setTickerStateProvider(() => isTickerActive);
  }

  @override
  void dispose() {
    super.dispose();
    _painter?.removeListener(notifyListeners);
    _tickerAwarePainter?.setTickerStateProvider(null);
  }

  @override
  Color get background => const Color(
      0x00000000); // TODO (GORDON): make this an override and add to canvas implementation

  @override
  bool paint(RenderTexture texture, double devicePixelRatio, Size size,
      double elapsedSeconds) {
    final painter = _painter;
    if (painter == null) {
      return false;
    }

    final shouldContinue = painter.advance(elapsedSeconds);
    painter.paint(texture.renderer, size, devicePixelRatio);
    return shouldContinue;
  }

  @override
  MouseCursor get cursor => _pointerEvent?.cursor ?? RiveDefaults.mouseCursor;

  @override
  bool hitTest(Offset position) => _pointerEvent?.hitTest(position) ?? false;

  @override
  void pointerEvent(PointerEvent event, HitTestEntry<HitTestTarget> entry) =>
      _pointerEvent?.pointerEvent(event, entry);

  @override
  RiveHitTestBehavior get hitTestBehavior =>
      _pointerEvent?.hitTestBehavior ?? RiveDefaults.hitTestBehaviour;

  @override
  void updateSize(Size size) => _riveArtboardLayoutMixin?.updateSize(size);

  @override
  Artboard? get artboard => _riveArtboardLayoutMixin?.artboard;
}

class _ArtboardWidgetRiveRendererState
    extends State<ArtboardWidgetRiveRenderer> {
  final RenderTexture renderTexture = RiveNative.instance.makeRenderTexture();

  ArtboardWidgetPainter? _painter;
  @override
  void initState() {
    _painter = ArtboardWidgetPainter(widget.painter);
    super.initState();
  }

  @override
  void dispose() {
    renderTexture.dispose();
    super.dispose();
    _painter?.dispose();
    _painter = null;
  }

  @override
  void didUpdateWidget(covariant ArtboardWidgetRiveRenderer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.painter != widget.painter) {
      setState(() {
        _painter = ArtboardWidgetPainter(widget.painter);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return renderTexture.widget(painter: _painter);
  }
}

class FlutterRiveRendererWidget extends LeafRenderObjectWidget {
  final ProceduralPainter? painter;

  const FlutterRiveRendererWidget({super.key, required this.painter});

  @override
  RenderObject createRenderObject(BuildContext context) {
    final tickerModeValue = TickerMode.of(context);

    return FlutterRiveRenderBox()
      ..painter = painter
      ..tickerModeEnabled = tickerModeValue;
  }

  @override
  void updateRenderObject(
      BuildContext context, covariant FlutterRiveRenderBox renderObject) {
    final tickerModeValue = TickerMode.of(context);

    renderObject
      ..painter = painter
      ..tickerModeEnabled = tickerModeValue;
  }
}

abstract class RiveRenderBox<T extends RivePainter> extends RenderBox
    implements MouseTrackerAnnotation {
  Ticker? _ticker;

  RivePointerEventMixin? _rivePointerEvent;
  RiveArtboardLayoutMixin? _riveArtboardResizeMixin;

  // TODO expose option through widget
  // @override
  // bool get isRepaintBoundary => false;

  T? _rivePainter;
  T? get rivePainter => _rivePainter;

  @mustCallSuper
  set painter(T? value) {
    markNeedsLayout();
    if (_rivePainter == value) {
      return;
    }
    _rivePainter?.removeListener(restartTickerIfStopped);
    _rivePainter = value;
    _rivePainter?.addListener(restartTickerIfStopped);
    _rivePointerEvent = _rivePainter is RivePointerEventMixin
        ? _rivePainter as RivePointerEventMixin
        : null;
    _setupTickerStateCallback();
    _riveArtboardResizeMixin = _rivePainter is RiveArtboardLayoutMixin
        ? _rivePainter as RiveArtboardLayoutMixin
        : null;
    restartTickerIfStopped();
  }

  bool get tickerModeEnabled => _tickerModeEnabled;
  bool _tickerModeEnabled = true;
  set tickerModeEnabled(bool value) {
    if (value != _tickerModeEnabled) {
      _tickerModeEnabled = value;

      if (_tickerModeEnabled) {
        startTicker();
      } else {
        stopTicker();
      }
    }
  }

  // TODO (Gordon): Re-explore this from the old runtime.
  // This is currently not set or used.
  bool get useArtboardSize => _useArtboardSize;
  bool _useArtboardSize = false;
  set useArtboardSize(bool value) {
    if (_useArtboardSize == value) {
      return;
    }
    _useArtboardSize = value;
    if (parent != null) {
      markNeedsLayoutForSizedByParentChange();
    }
  }

  // TODO (Gordon): Re-explore this from the old runtime.
  // This is currently not set or used.
  // Need to consider resizable artboards in the future.
  Size get artboardSize => _artboardSize;
  Size _artboardSize = Size.zero;
  set artboardSize(Size value) {
    if (_artboardSize == value) {
      return;
    }
    _artboardSize = value;
    if (parent != null) {
      markNeedsLayoutForSizedByParentChange();
    }
  }

  RiveHitTestBehavior get hitTestBehavior =>
      _rivePointerEvent?.hitTestBehavior ?? RiveDefaults.hitTestBehaviour;

  void rivePointerEvent(
          PointerEvent event, HitTestEntry<HitTestTarget> entry) =>
      _rivePointerEvent?.pointerEvent(event, entry);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // If hit testing is disabled, we don't need to perform any hit testing.
    if (hitTestBehavior == RiveHitTestBehavior.none) {
      return false;
    }

    bool hitTarget = false;
    if (size.contains(position)) {
      hitTarget = hitTestSelf(position);
      if (hitTarget) {
        // if hit add to results
        result.add(BoxHitTestEntry(this, position));
      }
    }

    // Let the hit continue to targets behind the animation.
    if (hitTestBehavior == RiveHitTestBehavior.transparent) {
      return false;
    }

    // Opaque will always return true, translucent will return true if we
    // hit a Rive listener target.
    return hitTarget;
  }

  @override
  bool hitTestSelf(Offset position) {
    switch (hitTestBehavior) {
      case RiveHitTestBehavior.none:
        return false;
      case RiveHitTestBehavior.opaque:
        return true; // Always hit
      case RiveHitTestBehavior.translucent:
      case RiveHitTestBehavior.transparent:
        {
          final value = _rivePointerEvent?.hitTest(position) ?? false;
          return value;
        }
    }
  }

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    assert(debugHandleEvent(event, entry));
    if (!attached) return;

    rivePointerEvent(event, entry);
  }

  @override
  MouseCursor get cursor =>
      _rivePointerEvent?.cursor ?? RiveDefaults.mouseCursor;

  @override
  PointerEnterEventListener? get onEnter => (event) {
        rivePointerEvent(event, HitTestEntry(this));
      };

  @override
  PointerExitEventListener? get onExit => (event) {
        rivePointerEvent(event, HitTestEntry(this));
      };

  bool _validForMouseTracker = true;
  @override
  bool get validForMouseTracker => _validForMouseTracker;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);

    _validForMouseTracker = true;
    _ticker = Ticker(frameCallback);
    if (tickerModeEnabled) {
      startTicker();
    }
  }

  @override
  void detach() {
    _validForMouseTracker = false;
    stopTicker();

    super.detach();
  }

  @override
  void dispose() {
    _cleanUpTickerStateCallback();
    _rivePainter?.removeListener(restartTickerIfStopped);
    _ticker?.dispose();
    _ticker = null;

    super.dispose();
  }

  void stopTicker() {
    _elapsedSeconds = 0;
    _prevTickerElapsedInSeconds = 0;

    _ticker?.stop();
  }

  /// Whether the ticker is currently active.
  bool get isTickerActive => _ticker?.isActive ?? false;

  /// Sets up the ticker state callback for the current painter.
  void _setupTickerStateCallback() {
    // Provide ticker state to painters that support it
    final painter = rivePainter;
    if (painter is RiveTickerAwarePainterMixin) {
      (painter as RiveTickerAwarePainterMixin)
          .setTickerStateProvider(() => isTickerActive);
    }
  }

  void _cleanUpTickerStateCallback() {
    final painter = rivePainter;
    if (painter is RiveTickerAwarePainterMixin) {
      (painter as RiveTickerAwarePainterMixin).setTickerStateProvider(null);
    }
  }

  void startTicker() {
    if (_rivePainter == null) {
      // If the painter is not set, we don't need to start the ticker.
      // Otherwise, we will start the ticker and then never stop it.
      return;
    }
    _elapsedSeconds = 0;
    _prevTickerElapsedInSeconds = 0;

    // Always ensure ticker is stopped before starting
    if (_ticker?.isActive ?? false) {
      _ticker?.stop();
    }
    _ticker?.start();
  }

  @protected
  @nonVirtual
  void restartTickerIfStopped() {
    if (_ticker != null && !_ticker!.isActive && tickerModeEnabled) {
      startTicker();
    }
  }

  /// Time between frame callbacks
  double _elapsedSeconds = 0;
  double get elapsedSeconds => _elapsedSeconds;

  /// The total time [_ticker] has been active in seconds
  double _prevTickerElapsedInSeconds = 0;

  void _calculateElapsedSeconds(Duration duration) {
    final double tickerElapsedInSeconds =
        duration.inMicroseconds.toDouble() / Duration.microsecondsPerSecond;
    assert(tickerElapsedInSeconds >= 0.0);

    _elapsedSeconds = tickerElapsedInSeconds - _prevTickerElapsedInSeconds;
    _prevTickerElapsedInSeconds = tickerElapsedInSeconds;
  }

  /// Whether the animation ticker should advance.
  bool get shouldAdvance;

  /// The frame callback for the ticker.
  ///
  /// Implementations of this method should start with a call to
  /// `super.frameCallback(duration)` to ensure the ticker is properly managed.
  @protected
  @mustCallSuper
  void frameCallback(Duration duration) {
    // TODO (Gordon): We also need to consider standard default behaviour for
    // what Rive should do when not visible on the screen:
    // - Advance and not draw
    // - Draw and advance
    // - Neither advance nor draw
    // - (Optional enum for users to choose)
    _calculateElapsedSeconds(duration);
  }

  @override
  bool get sizedByParent => !useArtboardSize;

  /// Finds the intrinsic size for the rive render box given the [constraints]
  /// and [sizedByParent].
  ///
  /// The difference between the intrinsic size returned here and the size we
  /// use for [performResize] is that the intrinsics contract does not allow
  /// infinite sizes, i.e. we cannot return biggest constraints.
  /// Consequently, the smallest constraint is returned in case we are
  /// [sizedByParent].
  Size _intrinsicSizeForConstraints(BoxConstraints constraints) {
    if (sizedByParent) {
      return constraints.smallest;
    }

    return constraints
        .constrainSizeAndAttemptToPreserveAspectRatio(artboardSize);
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    assert(height >= 0.0);
    // If not sized by parent, this returns the constrained (trying to preserve
    // aspect ratio) artboard size.
    // If sized by parent, this returns 0 (because an infinite width does not
    // make sense as an intrinsic width and is therefore not allowed).
    return _intrinsicSizeForConstraints(
            BoxConstraints.tightForFinite(height: height))
        .width;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    assert(height >= 0.0);
    // This is equivalent to the min intrinsic width because we cannot provide
    // any greater intrinsic width beyond which increasing the width never
    // decreases the preferred height.
    // When we have an artboard size, the intrinsic min and max width are
    // obviously equivalent and if sized by parent, we can also only return the
    // smallest width constraint (which is 0 in the case of intrinsic width).
    return _intrinsicSizeForConstraints(
            BoxConstraints.tightForFinite(height: height))
        .width;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    assert(width >= 0.0);
    // If not sized by parent, this returns the constrained (trying to preserve
    // aspect ratio) artboard size.
    // If sized by parent, this returns 0 (because an infinite height does not
    // make sense as an intrinsic height and is therefore not allowed).
    return _intrinsicSizeForConstraints(
            BoxConstraints.tightForFinite(width: width))
        .height;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    assert(width >= 0.0);
    // This is equivalent to the min intrinsic height because we cannot provide
    // any greater intrinsic height beyond which increasing the height never
    // decreases the preferred width.
    // When we have an artboard size, the intrinsic min and max height are
    // obviously equivalent and if sized by parent, we can also only return the
    // smallest height constraint (which is 0 in the case of intrinsic height).
    return _intrinsicSizeForConstraints(
            BoxConstraints.tightForFinite(width: width))
        .height;
  }

  // This replaces the old performResize method.
  @override
  Size computeDryLayout(BoxConstraints constraints) {
    return constraints.biggest;
  }

  @override
  void performLayout() {
    _riveArtboardResizeMixin?.updateSize(size);
    restartTickerIfStopped();
    if (!sizedByParent) {
      // We can use the intrinsic size here because the intrinsic size matches
      // the constrained artboard size when not sized by parent.
      size = _intrinsicSizeForConstraints(constraints);
    }
  }
}

class FlutterRiveRenderBox extends RiveRenderBox<ProceduralPainter> {
  bool _shouldAdvance = false;

  @override
  bool get shouldAdvance => _shouldAdvance;

  @override
  @mustCallSuper
  void frameCallback(Duration duration) {
    super.frameCallback(duration);

    _shouldAdvance = rivePainter?.advance(elapsedSeconds) ?? false;

    if (!_shouldAdvance) {
      stopTicker();
    }

    markNeedsPaint();
  }

  @protected
  @override
  void paint(PaintingContext context, Offset offset) {
    final Canvas canvas = context.canvas;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    final renderer = Renderer.make(canvas);
    rivePainter?.paint(renderer, size, 1.0);
    renderer.dispose();
    canvas.restore();
  }
}

abstract class RiveNativeRenderBox extends RiveRenderBox<RenderTexturePainter> {
  RenderTexture _renderTexture;

  @override
  bool get shouldAdvance => _shouldAdvance;
  bool _shouldAdvance = true;

  RiveNativeRenderBox(this._renderTexture) {
    _renderTexture.onTextureChanged = () {
      // Paint immediately after creating the texture ensures
      // that the texture is visually updated.
      paintTexture(0, forceShouldAdvance: true);
    };
  }

  double _devicePixelRatio = 1.0;

  /// The device pixel ratio used to determine the size of the paint area.
  double get devicePixelRatio => _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == devicePixelRatio) {
      return;
    }
    _devicePixelRatio = value;
    markNeedsLayout();
  }

  RenderTexture get renderTexture => _renderTexture;
  set renderTexture(RenderTexture value) {
    if (_renderTexture == value) {
      return;
    }
    _renderTexture = value;
    markNeedsPaint();
  }

  @override
  void performResize() {
    size = constraints.biggest;
  }

  @override
  void frameCallback(Duration duration) {
    super.frameCallback(duration);
    paintTexture(elapsedSeconds);
  }

  void paintTexture(double elapsedSeconds, {bool forceShouldAdvance = false}) {
    final painter = rivePainter;
    if (painter == null || !renderTexture.isReady || !hasSize) {
      return;
    }
    if (!renderTexture.clear(painter.background, painter.clear)) {
      markNeedsPaint();
      return;
    }
    final renderer = renderTexture.renderer;
    renderer.save();
    renderer.transform(Mat2D.fromScale(scaleWidth, scaleHeight));
    final shouldAdvance = painter.paint(
      renderTexture,
      devicePixelRatio,
      desiredSize,
      elapsedSeconds,
    );
    renderer.restore();
    _shouldAdvance = forceShouldAdvance == true || shouldAdvance;
    if (_shouldAdvance) {
      restartTickerIfStopped();
    } else {
      stopTicker();
    }
    if (!renderTexture.flush(devicePixelRatio)) {
      markNeedsPaint();
      return;
    }
    // Mark end of frame for profiler (no-op when profiling inactive)
    RiveProfiler.instance.endFrame();
    if (painter.paintsCanvas) {
      markNeedsPaint();
    }
  }

  double desiredTransformWidthScale = 1;
  double desiredTransformHeightScale = 1;
  double get scaleWidth => devicePixelRatio * desiredTransformWidthScale;
  double get scaleHeight => devicePixelRatio * desiredTransformHeightScale;
  Size get desiredSize => size;
  bool _markNeedsLayoutCalled = false;

  @override
  void markNeedsLayout() {
    _markNeedsLayoutCalled = true;
    super.markNeedsLayout();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_markNeedsLayoutCalled) {
      final currentTransformTo = getTransformTo(null);
      final newWidthScale = currentTransformTo.entry(0, 0).abs();
      final newHeightScale = currentTransformTo.entry(1, 1).abs();
      if (newWidthScale != desiredTransformWidthScale ||
          newHeightScale != desiredTransformHeightScale) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          markNeedsLayout();
        });
        desiredTransformWidthScale = newWidthScale;
        desiredTransformHeightScale = newHeightScale;
      }
      _markNeedsLayoutCalled = false;
    }
    super.paint(context, offset);
  }
}
