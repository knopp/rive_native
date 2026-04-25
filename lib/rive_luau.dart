import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:rive_native/rive_native.dart';

import 'src/ffi/rive_luau_ffi.dart'
    if (dart.library.js_interop) 'src/web/rive_luau_web.dart';

typedef LuauFunction = int Function(LuauState state);

enum ConsoleEntryType { print, error }

class ConsoleEntry {
  final ConsoleEntryType type;
  final String scriptName;
  final int lineNumber;
  final List<String> spans;

  ConsoleEntry({
    required this.type,
    required this.scriptName,
    required this.lineNumber,
    required this.spans,
  });
}

enum LuauType {
  nil,
  boolean,

  lightUserdata,
  number,
  vector,

  string, // all types above this must be value types, all types below this must be GC types - see iscollectable

  table,
  function,
  userdata,
  thread,
  buffer,
}

enum LuauStatus {
  ok,
  yielded,
  runtimeError,
  syntaxError, // legacy error code, preserved for compatibility
  memoryError,
  error,
  breaked,
  unknown,
}

enum GarbageCollection {
  /// Stops the garbage collector.
  stop,

  /// Restarts the garbage collector.
  restart,

  /// Performs a full garbage-collection cycle.
  collect,

  /// Current amount of memory (in Kbytes) in use by Lua.
  count,

  /// Remainder of dividing the current amount of bytes of memory in use by Lua
  /// by 1024.
  countBytes,

  /// Return 1 if GC is active (not stopped); note that GC may not be actively
  /// collecting even if it's running
  isRunning,

  /// Perform an explicit GC step, with the step size specified in KB. Garbage
  /// collection is handled by 'assists' that perform some amount of GC work
  /// matching pace of allocation explicit GC steps allow to perform some amount
  /// of work at custom points to offset the need for GC assists note that GC
  /// might also be paused for some duration (until bytes allocated meet the
  /// threshold) if an explicit step is performed during this pause, it will
  /// trigger the start of the next collection cycle
  step,

  /// tune GC parameters G (goal), S (step multiplier) and step size (usually
  /// best left ignored)
  ///
  /// garbage collection is incremental and tries to maintain the heap size to
  /// balance memory and performance overhead this overhead is determined by G
  /// (goal) which is the ratio between total heap size and the amount of live
  /// data in it G is specified in percentages; by default G=200% which means
  /// that the heap is allowed to grow to ~2x the size of live data.
  ///
  /// collector tries to collect S% of allocated bytes by interrupting the
  /// application after step size bytes were allocated. when S is too small,
  /// collector may not be able to catch up and the effective goal that can be
  /// reached will be larger. S is specified in percentages; by default S=200%
  /// which means that collector will run at ~2x the pace of allocations.
  ///
  /// it is recommended to set S in the interval [100 / (G - 100), 100 + 100 /
  /// (G - 100))] with a minimum value of 150%; for example:
  /// - for G=200%, S should be in the interval [150%, 200%]
  /// - for G=150%, S should be in the interval [200%, 300%]
  /// - for G=125%, S should be in the interval [400%, 500%]
  setGoal,
  setStepMul,
  setStepSize,
}

abstract class ScriptedRenderer {
  void end();
}

abstract class ScriptedDataValue {
  String get type;
  double numberValue();
  String stringValue();
  bool booleanValue();
  int colorValue();
}

abstract class ScriptedPath {}

abstract class PointerEvent {
  HitResult get hitResult;
}

abstract class LuauState {
  void dispose();

  /// Returns true if this VM has been disposed.
  /// After disposal, all operations on this state are invalid.
  bool get isDisposed;

  /// Returns the integer address of the underlying native Lua state pointer.
  /// Used to detect pointer reuse when swapping VMs.
  int get nativeAddress;

  static LuauState init(Factory riveFactory) {
    return makeLuauState(riveFactory);
  }

  /// Adopt a ScriptingVM created by C++ requestVM. Replaces the C++ scripting
  /// context with one compatible with Dart (factory + console callback).
  static LuauState adopt(int vmPointer, Factory riveFactory) {
    return adoptLuauState(vmPointer, riveFactory);
  }

  int integerAt(int index);
  int unsignedAt(int index);
  double numberAt(int index);
  String stringAt(int index);
  LuauType typeAt(int index);
  bool booleanAt(int index);
  Vec2D vectorAt(int index);

  bool isNil(int index) => typeAt(index) == LuauType.nil;
  bool isBoolean(int index) => typeAt(index) == LuauType.boolean;
  bool isLightUserdata(int index) => typeAt(index) == LuauType.lightUserdata;
  bool isNumber(int index) => typeAt(index) == LuauType.number;
  bool isVector(int index) => typeAt(index) == LuauType.vector;
  bool isString(int index) => typeAt(index) == LuauType.string;
  bool isTable(int index) => typeAt(index) == LuauType.table;
  bool isFunction(int index) => typeAt(index) == LuauType.function;
  bool isUserdata(int index) => typeAt(index) == LuauType.userdata;
  bool isThread(int index) => typeAt(index) == LuauType.thread;
  bool isBuffer(int index) => typeAt(index) == LuauType.buffer;

  void pushNil();
  void pushBoolean(bool value);
  void pushNumber(double value);
  void pushInteger(int value);
  void pushUnsigned(int value);
  void pushString(String value);
  void pushVector(Vec2D value);
  void pushMatrix(Mat2D value);
  void pushFunction(LuauFunction t, {String debugName = 'unknown'});
  int pushViewModel(InternalDataContext dataContext);
  int pushDataContext(InternalDataContext dataContext);

  /// Pushes a renderer onto the Lua stack.
  /// Returns null if the renderer is invalid (e.g., null pointer).
  ScriptedRenderer? pushRenderer(Renderer renderer);
  void pushArtboard(Artboard artboard, InternalDataContext? dataContext);
  void pushPath(RenderPath path);
  void pushViewModelInstanceValue(InternalViewModelInstanceValue value);

  /// Pushes a [RenderImage] onto the Lua stack as a ScriptedImage userdata.
  /// Returns 1 if successful, 0 if the image is null.
  int pushImage(RenderImage image);

  /// Pushes [AudioSource] onto the Lua stack as a ScriptedAudioSource userdata.
  /// Returns 1 if successful, 0 if the image is null.
  int pushAudio(AudioSource audio);
  void pushBlob(String name, Uint8List data);
  void setGlobal(String name) => setField(luaGlobalsIndex, name);

  /// Pushes on the top of the stack a copy of the element at the given [index].
  void pushValue(int index);

  /// Creates a table and pushes it on the stack, reserving memory for arraySize
  /// and recordCount.
  void createTable({int arraySize = 0, int recordCount = 0});

  /// Creates a meta table
  void createMetaTable(String name);
  int createViewModelInstance(File file, String viewModelName);
  int createViewModelInstanceFromInstance(
      File file, String viewModelName, String viewModelInstanceName);

  /// Removes the element at the given valid index, shifting down the elements
  /// above this index to fill the gap. Cannot be called with a pseudo-index,
  /// because a pseudo-index is not an actual stack position.
  void remove(int index);

  static const maxCStack = 8000;
  static const luaGlobalsIndex = -maxCStack - 2002;
  static const luaRegistryIndex = -maxCStack - 2000;

  /// Pushes onto the stack the value of the global [name]. Returns the type of
  /// that value.
  LuauType getGlobal(String name) => getField(luaGlobalsIndex, name);

  /// Pushes onto the stack the value t[k], where t is the value at the given
  /// index. As in Lua, this function may trigger a metamethod for the "index"
  /// event.
  ///
  /// Returns the type of the pushed value.
  LuauType getField(int index, String name);

  /// Does the equivalent to t[k] = v, where t is the value at the given index
  /// and v is the value on the top of the stack.
  ///
  /// This function pops the value from the stack. As in Lua, this function may
  /// trigger a metamethod for the "newindex" event
  void setField(int index, String name);

  /// The function pops a table from the stack and sets it as the metatable of
  /// the object at the given index.
  void setMetaTable(int index);

  bool equal(int index1, int index2);

  bool lessThan(int index1, int index2);

  /// Pushes onto the stack a string identifying the current position of the
  /// control at level [level] in the call stack. Typically this string has the
  /// following format: chunkname:currentline:
  void where(int level);

  /// lua_settop equivalent.
  void setTop(int index);

  ///  lua_gettop equivalent. Returns the number of elements in the stack, which
  ///  is also the index of the top element. Notice that a negative index -x is
  ///  equivalent to the positive index gettop - x + 1.
  int getTop();

  /// lua_unref equivalent. Stores the value at idx in the registry and returns
  /// an integer id to unref and get it. This is a strong reference, the object
  /// will not get garbage collected until it is unreffed.
  int ref(int idx);

  /// Removes the reference with id from the registry. The object will be
  /// garbage collected when it is no longer used elsewhere.
  void unref(int id);

  /// lua_rawgeti equivalent. Pushes onto the stack the value t[n], where t is
  /// the table at the given index. The access is raw, that is, it does not
  /// invoke the __index metamethod. Returns the type of the pushed value.
  LuauType rawGeti(int idx, int n);

  LuauType pushRef(int id) => rawGeti(luaRegistryIndex, id);

  void pop(int count) => setTop(-count - 1);

  /// Moves the top element into the given valid index without shifting any
  /// element (therefore replacing the value at that given index), and then pops
  /// the top element.
  void replace(int index);

  // Moves the top element into the given valid index, shifting up the elements
  // above this index to open space. This function cannot be called with a
  // pseudo-index, because a pseudo-index is not an actual stack position.
  void insert(int index);

  void load(String name, Uint8List bytecode, {int env = 0});
  bool registerModule(String name, Uint8List bytecode);
  void unregisterModule(String name);
  bool registerScript(String name, Uint8List bytecode);
  void clearStateWithFile(File file);

  void call(int numArgs, int numResults);
  LuauStatus pcall(int numArgs, int numResults);

  /// Controls the garbage collector. This function performs several tasks,
  /// according to the value of the [what] parameter.
  int gc(GarbageCollection what, [int data = 0]);

  int memoryUsedKB() =>
      gc(GarbageCollection.count) * 1024 + gc(GarbageCollection.countBytes);

  void dumpStack();

  final consoleHasData = ChangeNotifier();
  bool readConsole(List<ConsoleEntry> entries);
  void writeConsole(ConsoleEntry entry);

  // Data converter methods
  ScriptedDataValue pushDataValueNumber(double value);
  ScriptedDataValue pushDataValueString(String value);
  ScriptedDataValue pushDataValueBoolean(bool value);
  ScriptedDataValue pushDataValueColor(int value);
  ScriptedDataValue dataValueAt(int index);
  ScriptedPath pathAt(int index);

  PointerEvent pushPointerEvent(int id, Vec2D position);
  void pushPointerListenerInvocation(int id, Vec2D position,
      Vec2D previousPosition, int listenerType, double timeStamp);
  void pushKeyboardListenerInvocation(
      int key, int modifiers, bool isPressed, bool isRepeat);
  /// Node script `keyboardEvent` (KeyboardInvocation userdata), not listener
  /// [ScriptedInvocation].
  void pushScriptedKeyboardInvocation(
      int key, int modifiers, bool isPressed, bool isRepeat);
  void pushTextInputListenerInvocation(String text);
  /// Node script `textEvent` (TextInputInvocation userdata).
  void pushScriptedTextInputInvocation(String text);
  void pushFocusListenerInvocation(bool isFocus);
  void pushReportedEventListenerInvocation(double delaySeconds);
  void pushViewModelChangeListenerInvocation();
  void pushNoneListenerInvocation();
  void pushGamepadListenerInvocation(
      int deviceId, int buttonMask, double axis0);
  RenderPath? renderPath(ScriptedPath path, RenderPath renderPath);

  /// Sets the execution timeout in milliseconds.
  /// A value of 0 disables the timeout entirely.
  /// Default is 50ms.
  void setExecutionTimeout(int timeoutMs);

  /// Gets the current execution timeout in milliseconds.
  int getExecutionTimeout();

  /// Store a generator ref in the scripting context, keyed by asset ID.
  /// This allows ScriptAsset::initScriptedObjectWith() to look up refs
  /// without needing to serialize/deserialize through genRuntimeFile.
  void setGeneratorRef(int assetId, int ref);

  /// Get a generator ref from the scripting context by asset ID.
  /// Returns 0 if not found.
  int getGeneratorRef(int assetId);

  /// Clear all stored generator refs. Called when VM is disposed.
  void clearGeneratorRefs();

  /// Indicates to the vm that playback has stopped
  void stopPlayback();

  /// Indicates to the vm that playback has started
  void startPlayback();
}
