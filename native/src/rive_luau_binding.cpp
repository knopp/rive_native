#include "rive_native/rive_binding.hpp"
#include "rive_native/external.hpp"
#include "lua.h"
#include "lualib.h"
#include "rive/lua/rive_lua_libs.hpp"
#include "rive/renderer.hpp"
#include "rive/viewmodel/viewmodel_instance_viewmodel.hpp"
#include "rive/core/binary_writer.hpp"
#include "rive/core/vector_binary_stream.hpp"
#include "rive/assets/blob_asset.hpp"
#include "luau_error_parser.hpp"

const rive::RawPath& renderPathToRawPath(rive::Factory* factory,
                                         rive::RenderPath* renderPath);

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#include <emscripten/bind.h>
#include <emscripten/val.h>
#include <emscripten/html5.h>
#endif

#include <string>
#include <vector>
#include <chrono>
#include <cstring>

using namespace rive;

#ifdef __EMSCRIPTEN__
using namespace emscripten;
using ExternalPointer = WasmPtr;
using VoidCallback = emscripten::val;
#else
using ExternalPointer = void*;
typedef void (*VoidCallback)();
#endif

static int riveErrorHandler(lua_State* L);
static void* l_alloc(void* ud, void* ptr, size_t osize, size_t nsize)
{
    (void)ud;
    (void)osize;
    if (nsize == 0)
    {
        free(ptr);
        return NULL;
    }
    else
    {
        return realloc(ptr, nsize);
    }
}

static void interrupt(lua_State* L, int gc);

class DartExposedScriptingContext : public ScriptingContext
{
public:
#ifdef __EMSCRIPTEN__
    std::vector<emscripten::val> closures;
#endif
    VectorBinaryStream console;
    int timeoutMs = 1000;

    DartExposedScriptingContext(Factory* factory,
                                VoidCallback consoleHasDataCallback) :
        ScriptingContext(factory),
        m_consoleHasDataCallback(consoleHasDataCallback)
    {}

    int pCall(lua_State* state, int nargs, int nresults) override
    {
        // calculate stack position for message handler
        int hpos = lua_gettop(state) - nargs;
        lua_pushcfunction(state, riveErrorHandler, "riveErrorHandler");
        lua_insert(state, hpos);

        startTimedExecution(state);
        int ret = lua_pcall(state, nargs, nresults, hpos);
        endTimedExecution(state);
        lua_remove(state, hpos);
        return ret;
    }

    void printError(lua_State* state) override
    {
        const char* error = lua_tostring(state, -1);
        auto parsed = ErrorParser::parse(error);

        writeError(parsed);
    }

    void printBeginLine(lua_State* state) override
    {
        BinaryWriter writer(&console);
        lua_Debug ar;
        lua_getinfo(state, 1, "sl", &ar);
        writer.write((uint8_t)0);
        writer.write(ar.source);
        writer.writeVarUint((uint32_t)ar.currentline);
    }

    void writeError(const ErrorParser::ParsedError& error)
    {
        BinaryWriter writer(&console);
        writer.write((uint8_t)1);

        writer.writeVarUint((uint64_t)error.filename.size());
        writer.write((const uint8_t*)error.filename.data(),
                     (size_t)error.filename.size());

        writer.writeVarUint((uint32_t)error.line_number.value_or(0));

        writer.writeVarUint((uint64_t)error.message.size());
        writer.write((const uint8_t*)error.message.data(),
                     (size_t)error.message.size());
        printEndLine();
    }

    void print(Span<const char> data) override
    {
        if (data.size() == 0)
        {
            return;
        }
        BinaryWriter writer(&console);
        writer.writeVarUint((uint64_t)data.size());
        writer.write((const uint8_t*)data.data(), (size_t)data.size());
    }

    void printEndLine() override
    {
        BinaryWriter writer(&console);
        writer.writeVarUint((uint32_t)0);
        // Tell Dart new data is available (if we haven't told it yet). Then
        // let dart read back all the written data so far.
        if (!m_calledConsoleCallback)
        {
            m_calledConsoleCallback = true;
            m_consoleHasDataCallback();
        }
    }

    void clearConsole()
    {
        console.clear();
        m_calledConsoleCallback = false;
    }

    Span<uint8_t> consoleMemory() { return console.memory(); }

    void startTimedExecution(lua_State* state)
    {
        if (timeoutMs == 0)
        {
            return; // No timeout
        }
        lua_Callbacks* cb = lua_callbacks(state);
        cb->interrupt = interrupt;
        executionTime = std::chrono::steady_clock::now();
    }

    void endTimedExecution(lua_State* state)
    {
        lua_Callbacks* cb = lua_callbacks(state);
        cb->interrupt = nullptr;
    }

    std::chrono::time_point<std::chrono::steady_clock> executionTime;

private:
    VoidCallback m_consoleHasDataCallback;
    bool m_calledConsoleCallback = false;
};

static void interrupt(lua_State* L, int gc)
{
    if (gc >= 0)
    {
        return;
    }

    DartExposedScriptingContext* context =
        static_cast<DartExposedScriptingContext*>(lua_getthreaddata(L));

    if (context == nullptr)
    {
        return;
    }

    const auto now = std::chrono::steady_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                  now - context->executionTime)
                  .count();
    if (ms > context->timeoutMs)
    {
        lua_Callbacks* cb = lua_callbacks(L);
        cb->interrupt = nullptr;
        // reserve space for error string
        lua_rawcheckstack(L, 1);

        // Format human-readable error message
        char errorMsg[128];
        if (context->timeoutMs >= 1000)
        {
            double seconds = context->timeoutMs / 1000.0;
            snprintf(errorMsg,
                     sizeof(errorMsg),
                     "execution exceeded %.1f second%s timeout",
                     seconds,
                     seconds == 1.0 ? "" : "s");
        }
        else
        {
            snprintf(errorMsg,
                     sizeof(errorMsg),
                     "execution exceeded %d millisecond%s timeout",
                     context->timeoutMs,
                     context->timeoutMs == 1 ? "" : "s");
        }
        luaL_error(L, "%s", errorMsg);
    }
}

struct RiveLuauBufferResponse
{
#ifdef __EMSCRIPTEN__
    WasmPtr data;
#else
    uint8_t* data;
#endif
    size_t size;
};

EXPORT RiveLuauBufferResponse riveLuaConsole(lua_State* state)
{
    if (state == nullptr)
    {
        return {
#ifdef __EMSCRIPTEN__
            (WasmPtr) nullptr,
#else
            nullptr,
#endif
            0};
    }
    DartExposedScriptingContext* context =
        static_cast<DartExposedScriptingContext*>(lua_getthreaddata(state));
    auto memory = context->consoleMemory();

    return {
#ifdef __EMSCRIPTEN__
        (WasmPtr)memory.data(),
#else
        memory.data(),
#endif
        memory.size()};
}

EXPORT void riveLuaConsoleClear(lua_State* state)
{
    if (state == nullptr)
    {
        return;
    }
    DartExposedScriptingContext* context =
        static_cast<DartExposedScriptingContext*>(lua_getthreaddata(state));
    context->clearConsole();
}

// Creates a ScriptingVM that owns both the lua_State and context.
EXPORT ExternalPointer riveVMCreate(ExternalPointer factory,
                                    VoidCallback consoleHasDataCallback)
{
    auto context =
        std::make_unique<DartExposedScriptingContext>((Factory*)factory,
                                                      consoleHasDataCallback);
    auto* vm = new ScriptingVM(std::move(context));
    return (ExternalPointer)vm;
}

// Releases a reference to a ScriptingVM. The VM will be destroyed when
// all references (including those held by ScriptedObjects) are released.
EXPORT void riveVMDestroy(ExternalPointer vmPtr)
{
    if (!vmPtr)
    {
        return;
    }
    static_cast<ScriptingVM*>((void*)vmPtr)->unref();
}

// Gets the lua_State* from a ScriptingVM (for operations that need it).
EXPORT lua_State* riveVMGetState(ExternalPointer vmPtr)
{
    if (!vmPtr)
    {
        return nullptr;
    }
    return static_cast<ScriptingVM*>((void*)vmPtr)->state();
}

// Gets console output from a ScriptingVM.
EXPORT RiveLuauBufferResponse riveVMConsole(ExternalPointer vmPtr)
{
    if (!vmPtr)
    {
        return {
#ifdef __EMSCRIPTEN__
            (WasmPtr) nullptr,
#else
            nullptr,
#endif
            0};
    }
    auto* vm = static_cast<ScriptingVM*>((void*)vmPtr);
    auto* context = static_cast<DartExposedScriptingContext*>(vm->context());
    auto memory = context->consoleMemory();
    return {
#ifdef __EMSCRIPTEN__
        (WasmPtr)memory.data(),
#else
        memory.data(),
#endif
        memory.size()};
}

// Clears console output from a ScriptingVM.
EXPORT void riveVMConsoleClear(ExternalPointer vmPtr)
{
    if (!vmPtr)
    {
        return;
    }
    auto* vm = static_cast<ScriptingVM*>((void*)vmPtr);
    auto* context = static_cast<DartExposedScriptingContext*>(vm->context());
    context->clearConsole();
}

// Calls a function in the ScriptingVM.
EXPORT void riveVMCall(ExternalPointer vmPtr, int nargs, int nresults)
{
    if (!vmPtr)
    {
        return;
    }
    auto* vm = static_cast<ScriptingVM*>((void*)vmPtr);
    try
    {
        lua_call(vm->state(), nargs, nresults);
    }
    catch (const std::exception& ex)
    {
        fprintf(stderr, "got lua exception %s\n", ex.what());
    }
}

// Registers a module in the ScriptingVM.
EXPORT bool riveVMRegisterModule(ExternalPointer vmPtr,
                                 const char* name,
                                 const char* data,
                                 size_t size)
{
    if (!vmPtr)
    {
        return false;
    }
    auto* vm = static_cast<ScriptingVM*>((void*)vmPtr);
    auto* context = static_cast<DartExposedScriptingContext*>(vm->context());
    context->startTimedExecution(vm->state());
    auto result =
        ScriptingVM::registerModule(vm->state(),
                                    name,
                                    Span<uint8_t>((uint8_t*)data, size));
    context->endTimedExecution(vm->state());
    return result;
}

// Unregisters a module from the ScriptingVM.
EXPORT void riveVMUnregisterModule(ExternalPointer vmPtr, const char* name)
{
    if (!vmPtr)
    {
        return;
    }
    auto* vm = static_cast<ScriptingVM*>((void*)vmPtr);
    ScriptingVM::unregisterModule(vm->state(), name);
}

// Adopts a ScriptingVM from ScriptingWorkspace, replacing its context with
// a DartExposedScriptingContext. The old context is properly cleaned up.
EXPORT void riveVMAdopt(ExternalPointer vmPtr,
                        ExternalPointer factory,
                        VoidCallback consoleHasDataCallback)
{
    if (!vmPtr)
    {
        return;
    }
    auto* vm = static_cast<ScriptingVM*>((void*)vmPtr);

    // Create a DartExposedScriptingContext with the factory and console
    // callback. replaceContext handles cleanup of old context and updates
    // lua thread data.
    auto newContext =
        std::make_unique<DartExposedScriptingContext>((Factory*)factory,
                                                      consoleHasDataCallback);
    vm->replaceContext(std::move(newContext));
}

EXPORT void riveLuaCall(lua_State* state, int nargs, int nresults)
{
    try
    {
        lua_call(state, nargs, nresults);
    }
    catch (const std::exception& ex)
    {
        fprintf(stderr, "got lua exception %s\n", ex.what());
    }
}

EXPORT bool riveLuaRegisterModule(lua_State* state,
                                  const char* name,
                                  const char* data,
                                  size_t size)
{
    DartExposedScriptingContext* context =
        static_cast<DartExposedScriptingContext*>(lua_getthreaddata(state));
    context->startTimedExecution(state);
    auto result =
        ScriptingVM::registerModule(state,
                                    name,
                                    Span<uint8_t>((uint8_t*)data, size));
    context->endTimedExecution(state);
    return result;
}

EXPORT void riveLuaUnregisterModule(lua_State* state, const char* name)
{
    ScriptingVM::unregisterModule(state, name);
}

EXPORT void riveLuaCreateMetaTable(lua_State* state, const char* name)
{
    // create metatable for T
    luaL_newmetatable(state, name);
    lua_pop(state, 1);
}

EXPORT int riveLuaCreateViewModelInstance(lua_State* state,
                                          File* file,
                                          const char* viewModelName)
{
    if (file == nullptr)
    {
        return 0;
    }
    rcp<ViewModelInstance> vmi = file->createViewModelInstance(viewModelName);
    if (vmi)
    {

        lua_newrive<ScriptedViewModel>(state,
                                       state,
                                       ref_rcp(vmi->viewModel()),
                                       vmi);
        return 1;
    }
    return 0;
}

EXPORT int riveLuaCreateViewModelInstanceFromInstance(
    lua_State* state,
    File* file,
    const char* viewModelName,
    const char* viewModelInstanceName)
{
    if (file == nullptr)
    {
        return 0;
    }
    rcp<ViewModelInstance> vmi =
        file->createViewModelInstance(viewModelName, viewModelInstanceName);
    if (vmi)
    {

        lua_newrive<ScriptedViewModel>(state,
                                       state,
                                       ref_rcp(vmi->viewModel()),
                                       vmi);
        return 1;
    }
    return 0;
}

EXPORT bool riveLuaRegisterScript(lua_State* state,
                                  const char* name,
                                  const char* data,
                                  size_t size)
{
    return ScriptingVM::registerScript(state,
                                       name,
                                       Span<uint8_t>((uint8_t*)data, size));
}

EXPORT void riveStackDump(lua_State* state);
// Example C function to serve as an error handler
static int riveErrorHandler(lua_State* L)
{
    DartExposedScriptingContext* context =
        static_cast<DartExposedScriptingContext*>(lua_getthreaddata(L));
    context->printError(L);

    // lua_Debug ar;
    // lua_getinfo(L, 1, "sl", &ar);
    // // writer.write(ar.source);
    // // writer.writeVarUint((uint32_t)ar.currentline);
    // fprintf(stderr,
    //         "the source and line: %s %i\n",
    //         ar.source,
    //         (uint32_t)ar.currentline);
    // DartExposedScriptingContext* context =
    //     static_cast<DartExposedScriptingContext*>(lua_getthreaddata(L));
    // auto memory = context->consoleMemory();

    // Optionally, you can push a new value onto the stack to be returned by
    // lua_pcall For example, push a specific error code or a more detailed
    // message
    const char* error = lua_tostring(L, -1);
    lua_pushstring(L, error);
    return 1; // Number of return values
    // return 0;
}

EXPORT int riveLuaPCall(lua_State* state, int nargs, int nresults)
{
    DartExposedScriptingContext* context =
        static_cast<DartExposedScriptingContext*>(lua_getthreaddata(state));

    return context->pCall(state, nargs, nresults);
}

EXPORT void riveLuaPushArtboard(lua_State* state,
                                WrappedArtboard* wrappedArtboard,
                                DataContext* dataContext)
{
    if (state == nullptr || wrappedArtboard == nullptr)
    {
        return;
    }
    lua_newrive<ScriptedArtboard>(state,
                                  state,
                                  wrappedArtboard->file(),
                                  wrappedArtboard->artboard()->instance(),
                                  nullptr,
                                  ref_rcp(dataContext));
}

EXPORT void riveLuaPushPath(lua_State* state,
                            Factory* factory,
                            RenderPath* renderPath)
{
    if (state == nullptr || renderPath == nullptr)
    {
        return;
    }
    const rive::RawPath& rawPath = renderPathToRawPath(factory, renderPath);
    lua_newrive<ScriptedPathData>(state, &rawPath);
}

EXPORT ScriptedRenderer* riveLuaPushRenderer(lua_State* state,
                                             Renderer* renderer)
{
    if (state == nullptr || renderer == nullptr)
    {
        return nullptr;
    }
    return lua_newrive<ScriptedRenderer>(state, renderer);
}

EXPORT ScriptedMat2D* riveLuaPushFullMatrix(lua_State* state,
                                            float x1,
                                            float x2,
                                            float y1,
                                            float y2,
                                            float tx,
                                            float ty)
{
    if (state == nullptr)
    {
        return nullptr;
    }
    return lua_newrive<ScriptedMat2D>(state, x1, x2, y1, y2, tx, ty);
}

EXPORT ScriptedMat2D* riveLuaPushMatrix(lua_State* state)
{
    if (state == nullptr)
    {
        return nullptr;
    }
    return lua_newrive<ScriptedMat2D>(state);
}

EXPORT void riveLuaPushMatrixX(ScriptedMat2D* scriptedMat,
                               float x1,
                               float x2,
                               float tx)
{
    if (scriptedMat == nullptr)
    {
        return;
    }
    scriptedMat->value.xx(x1);
    scriptedMat->value.xy(x2);
    scriptedMat->value.tx(tx);
}

EXPORT void riveLuaPushMatrixY(ScriptedMat2D* scriptedMat,
                               float y1,
                               float y2,
                               float ty)
{
    if (scriptedMat == nullptr)
    {
        return;
    }
    scriptedMat->value.yx(y1);
    scriptedMat->value.yy(y2);
    scriptedMat->value.ty(ty);
}

EXPORT ScriptedDataValue* riveLuaDataValue(lua_State* state, int index)
{
    if (state == nullptr)
    {
        return nullptr;
    }
    auto scriptedDataValue = (ScriptedDataValue*)lua_touserdata(state, index);
    return scriptedDataValue;
}

EXPORT ScriptedPathData* riveLuaPath(lua_State* state, int index)
{
    if (state == nullptr)
    {
        return nullptr;
    }
    auto scriptedPath = (ScriptedPathData*)lua_touserdata(state, index);
    return scriptedPath;
}

EXPORT RenderPath* riveLuaRenderPath(lua_State* state, ScriptedPathData* path)
{
    auto renderPath = path->renderPath(state);
    renderPath->ref();
    return renderPath;
}

EXPORT ScriptedDataValueNumber* riveLuaPushDataValueNumber(lua_State* state,
                                                           float value)
{
    if (state == nullptr)
    {
        return nullptr;
    }

    return lua_newrive<ScriptedDataValueNumber>(state, state, value);
}

EXPORT ScriptedDataValueString* riveLuaPushDataValueString(lua_State* state,
                                                           const char* value)
{
    if (state == nullptr)
    {
        return nullptr;
    }

    return lua_newrive<ScriptedDataValueString>(state, state, value);
}

EXPORT ScriptedDataValueBoolean* riveLuaPushDataValueBoolean(lua_State* state,
                                                             bool value)
{
    if (state == nullptr)
    {
        return nullptr;
    }

    return lua_newrive<ScriptedDataValueBoolean>(state, state, value);
}

EXPORT ScriptedDataValueColor* riveLuaPushDataValueColor(lua_State* state,
                                                         int value)

{
    if (state == nullptr)
    {
        return nullptr;
    }

    return lua_newrive<ScriptedDataValueColor>(state, state, value);
}

EXPORT ScriptedPointerEvent* riveLuaPushPointerEvent(lua_State* state,
                                                     uint8_t id,
                                                     float x,
                                                     float y)
{
    return lua_newrive<ScriptedPointerEvent>(state, id, Vec2D(x, y));
}

EXPORT ScriptedInvocation* riveLuaPushPointerListenerInvocation(
    lua_State* state,
    uint8_t id,
    float x,
    float y,
    float prevX,
    float prevY,
    int hitType,
    float timeStamp)
{
    auto p = ListenerInvocation::pointer(Vec2D(x, y),
                                         Vec2D(prevX, prevY),
                                         id,
                                         (ListenerType)(hitType),
                                         timeStamp);
    return lua_newrive<ScriptedInvocation>(state, p);
}

EXPORT ScriptedInvocation* riveLuaPushKeyboardListenerInvocation(
    lua_State* state,
    uint32_t key,
    uint8_t modifiers,
    uint8_t isPressed,
    uint8_t isRepeat)
{
    if (state == nullptr)
    {
        return nullptr;
    }
    auto k = ListenerInvocation::keyboard(static_cast<Key>(key),
                                          static_cast<KeyModifiers>(modifiers),
                                          isPressed != 0,
                                          isRepeat != 0);
    return lua_newrive<ScriptedInvocation>(state, k);
}

/// Scripted node `keyboardEvent` callback (KeyboardInvocation userdata), not
/// listener ScriptedInvocation.
EXPORT ScriptedKeyboardInvocation* riveLuaPushScriptedKeyboardInvocation(
    lua_State* state,
    uint32_t key,
    uint8_t modifiers,
    uint8_t isPressed,
    uint8_t isRepeat)
{
    if (state == nullptr)
    {
        return nullptr;
    }
    return lua_newrive<ScriptedKeyboardInvocation>(
        state,
        static_cast<Key>(key),
        static_cast<KeyModifiers>(modifiers),
        isPressed != 0,
        isRepeat != 0);
}

/// Scripted node `textEvent` callback (TextInputInvocation userdata).
EXPORT ScriptedTextInputInvocation* riveLuaPushScriptedTextInputInvocation(
    lua_State* state,
    const char* utf8Text)
{
    if (state == nullptr)
    {
        return nullptr;
    }
    return lua_newrive<ScriptedTextInputInvocation>(
        state,
        std::string(utf8Text ? utf8Text : ""));
}

EXPORT ScriptedInvocation* riveLuaPushTextInputListenerInvocation(
    lua_State* state,
    const char* utf8Text)
{
    if (state == nullptr)
    {
        return nullptr;
    }
    auto t = ListenerInvocation::textInput(utf8Text ? utf8Text : "");
    return lua_newrive<ScriptedInvocation>(state, std::move(t));
}

EXPORT ScriptedInvocation* riveLuaPushFocusListenerInvocation(lua_State* state,
                                                              uint8_t isFocus)
{
    if (state == nullptr)
    {
        return nullptr;
    }
    auto f = ListenerInvocation::focus(nullptr, isFocus != 0);
    return lua_newrive<ScriptedInvocation>(state, f);
}

EXPORT ScriptedInvocation* riveLuaPushReportedEventListenerInvocation(
    lua_State* state,
    float delaySeconds)
{
    if (state == nullptr)
    {
        return nullptr;
    }
    auto e = ListenerInvocation::reportedEvent(nullptr, delaySeconds);
    return lua_newrive<ScriptedInvocation>(state, e);
}

EXPORT ScriptedInvocation* riveLuaPushViewModelChangeListenerInvocation(
    lua_State* state)
{
    if (state == nullptr)
    {
        return nullptr;
    }
    auto v = ListenerInvocation::viewModelChange(nullptr);
    return lua_newrive<ScriptedInvocation>(state, v);
}

EXPORT ScriptedInvocation* riveLuaPushNoneListenerInvocation(lua_State* state)
{
    if (state == nullptr)
    {
        return nullptr;
    }
    auto n = ListenerInvocation::none();
    return lua_newrive<ScriptedInvocation>(state, n);
}

EXPORT ScriptedInvocation* riveLuaPushGamepadListenerInvocation(
    lua_State* state,
    int32_t deviceId,
    uint64_t buttonMask,
    float axis0)
{
    if (state == nullptr)
    {
        return nullptr;
    }
    auto g = ListenerInvocation::gamepad(deviceId, buttonMask, axis0);
    return lua_newrive<ScriptedInvocation>(state, g);
}

EXPORT uint8_t riveLuaPointerEventHitResult(ScriptedPointerEvent* pointerEvent)
{
    if (pointerEvent == nullptr)
    {
        return 0;
    }
    return (uint8_t)pointerEvent->m_hitResult;
}

EXPORT const char* riveLuaScriptedDataValueType(
    ScriptedDataValue* scriptedDataValue)
{
    if (scriptedDataValue == nullptr)
    {
        return toCString("");
    }
    if (scriptedDataValue->isNumber())
    {
        return toCString("DataValueNumber");
    }
    if (scriptedDataValue->isString())
    {
        return toCString("DataValueString");
    }
    if (scriptedDataValue->isBoolean())
    {
        return toCString("DataValueBoolean");
    }
    if (scriptedDataValue->isColor())
    {
        return toCString("DataValueColor");
    }
    return toCString("");
}

EXPORT const float riveLuaScriptedDataValueNumberValue(
    ScriptedDataValue* scriptedDataValue)
{
    if (scriptedDataValue != nullptr &&
        scriptedDataValue->dataValue() != nullptr &&
        scriptedDataValue->dataValue()->is<DataValueNumber>())
    {
        return scriptedDataValue->dataValue()->as<DataValueNumber>()->value();
    }
    return 0;
}

EXPORT const char* riveLuaScriptedDataValueStringValue(
    ScriptedDataValue* scriptedDataValue)
{
    if (scriptedDataValue != nullptr &&
        scriptedDataValue->dataValue() != nullptr &&
        scriptedDataValue->dataValue()->is<DataValueString>())
    {
        return toCString(
            scriptedDataValue->dataValue()->as<DataValueString>()->value());
    }
    return toCString("");
}

EXPORT bool riveLuaScriptedDataValueBooleanValue(
    ScriptedDataValue* scriptedDataValue)
{
    if (scriptedDataValue != nullptr &&
        scriptedDataValue->dataValue() != nullptr &&
        scriptedDataValue->dataValue()->is<DataValueBoolean>())
    {
        return scriptedDataValue->dataValue()->as<DataValueBoolean>()->value();
    }
    return false;
}

EXPORT int riveLuaScriptedDataValueColorValue(
    ScriptedDataValue* scriptedDataValue)
{
    if (scriptedDataValue != nullptr &&
        scriptedDataValue->dataValue() != nullptr &&
        scriptedDataValue->dataValue()->is<DataValueColor>())
    {
        return scriptedDataValue->dataValue()->as<DataValueColor>()->value();
    }
    return false;
}

EXPORT void riveLuaPushViewModelInstanceValue(
    lua_State* state,
    ViewModelInstanceValue* viewModelInstanceValue)
{
    if (state == nullptr || viewModelInstanceValue == nullptr)
    {
        return;
    }
    switch (viewModelInstanceValue->coreType())
    {
        case ViewModelInstanceViewModelBase::typeKey:
        {
            auto vm = viewModelInstanceValue->as<ViewModelInstanceViewModel>();
            auto vmi = vm->referenceViewModelInstance();
            if (vmi == nullptr)
            {
                fprintf(stderr,
                        "riveLuaPushViewModelInstanceValue - passed in a "
                        "ViewModelInstanceViewModel with no associated "
                        "ViewModelInstance.\n");
                return;
            }

            lua_newrive<ScriptedViewModel>(state,
                                           state,
                                           ref_rcp(vmi->viewModel()),
                                           vmi);
            break;
        }
        default:
            fprintf(stderr,
                    "riveLuaPushViewModelInstanceValue - passed in an "
                    "unhandled ViewModelInstanceValue type: %i\n",
                    viewModelInstanceValue->coreType());
            break;
    }
    // lua_newrive<ScriptedRenderer>(state, renderer);
}

EXPORT void riveLuaScriptedRendererEnd(ScriptedRenderer* renderer)
{
    if (renderer == nullptr)
    {
        return;
    }
    renderer->end();
}

EXPORT void riveStackDump(lua_State* state)
{
    int i;
    int top = lua_gettop(state);
    for (i = 1; i <= top; i++)
    { /* repeat for each level */
        int t = lua_type(state, i);
        switch (t)
        {

            case LUA_TSTRING: /* strings */
                fprintf(stderr,
                        "  (%i)[STRING] %s\n",
                        i,
                        lua_tostring(state, i));
                break;

            case LUA_TBOOLEAN: /* booleans */
                fprintf(stderr,
                        "  (%i)[BOOLEAN] %s\n",
                        i,
                        lua_toboolean(state, i) ? "true" : "false");
                break;

            case LUA_TNUMBER: /* numbers */
                fprintf(stderr,
                        "  (%i)[NUMBER] %g\n",
                        i,
                        lua_tonumber(state, i));
                break;

            default: /* other values */
                fprintf(stderr, "  (%i)[%s]\n", i, lua_typename(state, t));
                break;
        }
    }
    fprintf(stderr, "\n"); /* end the listing */
}

EXPORT void clearScriptingVM(File* file)
{
    if (file == nullptr)
    {
        return;
    }
    file->clearScriptingVM();
}

EXPORT int riveLuaPushDataContext(lua_State* state, DataContext* dataContext)
{
    if (state == nullptr || dataContext == nullptr)
    {
        return 0;
    }
    lua_newrive<ScriptedDataContext>(state, state, ref_rcp(dataContext));
    return 1;
}

EXPORT int riveLuaPushDataContextViewModel(lua_State* state,
                                           DataContext* dataContext)
{
    if (state == nullptr || dataContext == nullptr)
    {
        return 0;
    }
    auto viewModelInstance = dataContext->viewModelInstance();
    if (viewModelInstance == nullptr)
    {
        return 0;
    }
    lua_newrive<ScriptedViewModel>(state,
                                   state,
                                   ref_rcp(viewModelInstance->viewModel()),
                                   viewModelInstance);
    return 1;
}

EXPORT void riveLuaPushBlob(lua_State* state,
                            const char* name,
                            const uint8_t* data,
                            size_t size)
{
    if (state == nullptr)
    {
        return;
    }
    auto scriptedBlob = lua_newrive<ScriptedBlob>(state);
    if (data != nullptr && size > 0)
    {
        auto blobAsset = make_rcp<BlobAsset>();
        if (name != nullptr)
        {
            blobAsset->name(name);
        }
        SimpleArray<uint8_t> bytes(data, size);
        blobAsset->decode(bytes, nullptr);
        scriptedBlob->asset = blobAsset;
    }
}

#ifdef WITH_RIVE_AUDIO

// Push an AudioSource onto the Lua stack as a ScriptedAudioSource userdata.
// Returns 1 if successful, 0 if the image is null.
#ifndef __EMSCRIPTEN__
EXPORT int riveLuaPushAudioSource(lua_State* state, AudioSource* audioSource)
#else
EXPORT int riveLuaPushAudioSource(WasmPtr state, WasmPtr audioSource)
#endif
{
#ifdef __EMSCRIPTEN__
    lua_State* L = (lua_State*)state;
    AudioSource* audio = (AudioSource*)audioSource;
#else
    lua_State* L = state;
    AudioSource* audio = audioSource;
#endif
    if (L == nullptr || audio == nullptr)
    {
        return 0;
    }
    auto scriptedAudioSource = lua_newrive<ScriptedAudioSource>(L);
    scriptedAudioSource->source(ref_rcp(audio));
    return 1;
}
#endif

EXPORT void riveLuaSetExecutionTimeout(lua_State* state, int timeoutMs)
{
    if (state == nullptr)
    {
        return;
    }
    DartExposedScriptingContext* context =
        static_cast<DartExposedScriptingContext*>(lua_getthreaddata(state));
    context->timeoutMs = timeoutMs;
}

EXPORT int riveLuaGetExecutionTimeout(lua_State* state)
{
    if (state == nullptr)
    {
        return 50;
    }
    DartExposedScriptingContext* context =
        static_cast<DartExposedScriptingContext*>(lua_getthreaddata(state));
    return context->timeoutMs;
}

// Editor-only: Store generator ref in context for direct ScriptedObject
// reinitialization without genRuntimeFile.
EXPORT void riveLuaSetGeneratorRef(lua_State* state, uint32_t assetId, int ref)
{
    if (state == nullptr)
    {
        return;
    }
    ScriptingContext* context =
        static_cast<ScriptingContext*>(lua_getthreaddata(state));
    if (context != nullptr)
    {
        context->setGeneratorRef(assetId, ref);
    }
}

EXPORT int riveLuaGetGeneratorRef(lua_State* state, uint32_t assetId)
{
    if (state == nullptr)
    {
        return 0;
    }
    ScriptingContext* context =
        static_cast<ScriptingContext*>(lua_getthreaddata(state));
    if (context == nullptr)
    {
        return 0;
    }
    return context->getGeneratorRef(assetId);
}

EXPORT void riveLuaClearGeneratorRefs(lua_State* state)
{
    if (state == nullptr)
    {
        return;
    }
    ScriptingContext* context =
        static_cast<ScriptingContext*>(lua_getthreaddata(state));
    if (context != nullptr)
    {
        context->clearGeneratorRefs();
    }
}

#ifdef WITH_RIVE_TOOLS
EXPORT void riveLuaStopPlayback(lua_State* state)
{
    if (state == nullptr)
    {
        return;
    }
    ScriptingContext* context =
        static_cast<ScriptingContext*>(lua_getthreaddata(state));
    if (context)
    {
        context->isPlaying(false);
        context->disposeOrphanScriptedProperties();
    }
}

EXPORT void riveLuaStartPlayback(lua_State* state)
{
    if (state == nullptr)
    {
        return;
    }
    ScriptingContext* context =
        static_cast<ScriptingContext*>(lua_getthreaddata(state));
    if (context)
    {
        context->isPlaying(true);
    }
}
#endif

// Update a File's scripting state to point to a ScriptingVM.
// The VM's refcount is incremented, so the caller should call riveVMDestroy
// when they no longer need their reference.
#ifndef __EMSCRIPTEN__
EXPORT void riveFileSetScriptingVM(File* file, ScriptingVM* vm)
#else
EXPORT void riveFileSetScriptingVM(WasmPtr filePtr, WasmPtr vmPtr)
#endif
{
#ifdef __EMSCRIPTEN__
    File* file = (File*)filePtr;
    ScriptingVM* vm = (ScriptingVM*)vmPtr;
#endif
    if (file == nullptr)
    {
        return;
    }
    file->setScriptingVM(ref_rcp(vm));
}

// Push a RenderImage onto the Lua stack as a ScriptedImage userdata.
// Returns 1 if successful, 0 if the image is null.
#ifndef __EMSCRIPTEN__
EXPORT int riveLuaPushImage(lua_State* state, RenderImage* renderImage)
#else
EXPORT int riveLuaPushImage(WasmPtr state, WasmPtr renderImage)
#endif
{
#ifdef __EMSCRIPTEN__
    lua_State* L = (lua_State*)state;
    RenderImage* img = (RenderImage*)renderImage;
#else
    lua_State* L = state;
    RenderImage* img = renderImage;
#endif

    if (L == nullptr || img == nullptr)
    {
        return 0;
    }

    auto scriptedImage = lua_newrive<ScriptedImage>(L);
    // ref_rcp increments ref count, rcp<> destructor will decrement when
    // ScriptedImage is GC'd
    scriptedImage->image = ref_rcp(img);
    return 1;
}

#ifdef __EMSCRIPTEN__

static int lua_callback(lua_State* L)
{
    DartExposedScriptingContext* context =
        static_cast<DartExposedScriptingContext*>(lua_getthreaddata(L));
    unsigned functionIndex = lua_tounsignedx(L, lua_upvalueindex(1), nullptr);
    emscripten::val result =
        context->closures[functionIndex]((WasmPtr)L, functionIndex);
    return result.as<int>();
}

EXPORT void riveLuaPushClosure(WasmPtr state,
                               emscripten::val fn,
                               WasmPtr debugname)
{
    lua_State* L = (lua_State*)state;
    const char* name = (const char*)debugname;

    if (L == nullptr)
    {
        return;
    }

    DartExposedScriptingContext* context =
        static_cast<DartExposedScriptingContext*>(lua_getthreaddata(L));

    int upvalue = (int)context->closures.size();
    context->closures.push_back(fn);

    lua_pushinteger(L, upvalue);
    lua_pushcclosurek(L, lua_callback, name, 1, nullptr);
}

EMSCRIPTEN_BINDINGS(RiveLuauBinding)
{
    function("riveLuaPushClosure", &riveLuaPushClosure);

    value_array<RiveLuauBufferResponse>("RiveLuauBufferResponse")
        .element(&RiveLuauBufferResponse::data)
        .element(&RiveLuauBufferResponse::size);

    function("riveLuaConsole",
             optional_override([](WasmPtr state) -> RiveLuauBufferResponse {
                 return riveLuaConsole((lua_State*)state);
             }));
    function("riveLuaPushImage", &riveLuaPushImage);

    // VM lifecycle functions - must be in EMSCRIPTEN_BINDINGS because they take
    // emscripten::val callbacks
    function("riveVMCreate",
             optional_override(
                 [](WasmPtr factory,
                    emscripten::val consoleHasDataCallback) -> WasmPtr {
                     return (WasmPtr)riveVMCreate((ExternalPointer)factory,
                                                  consoleHasDataCallback);
                 }));
    function("riveVMDestroy", optional_override([](WasmPtr vmPtr) -> void {
                 riveVMDestroy((ExternalPointer)vmPtr);
             }));
    function("riveVMGetState", optional_override([](WasmPtr vmPtr) -> WasmPtr {
                 return (WasmPtr)riveVMGetState((ExternalPointer)vmPtr);
             }));
    function(
        "riveVMAdopt",
        optional_override([](WasmPtr vmPtr,
                             WasmPtr factory,
                             emscripten::val consoleHasDataCallback) -> void {
            riveVMAdopt((ExternalPointer)vmPtr,
                        (ExternalPointer)factory,
                        consoleHasDataCallback);
        }));
}
#endif