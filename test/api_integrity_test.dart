// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/layout_engine.dart';
import 'package:rive_native/rive_native.dart' as rive;
import 'package:rive_native/src/ffi/dynamic_library_helper.dart';

final DynamicLibrary nativeLib = DynamicLibraryHelper.nativeLib;
final bool Function() _builtWithRiveTools =
    nativeLib.lookup<NativeFunction<Bool Function()>>('builtWithRiveTools')
    .asFunction();

final int Function() _debugFileCount = nativeLib
    .lookup<NativeFunction<Uint32 Function()>>('debugFileCount')
    .asFunction();
final int Function() _debugArtboardCount = nativeLib
    .lookup<NativeFunction<Uint32 Function()>>('debugArtboardCount')
    .asFunction();
final int Function() _debugStateMachineCount = nativeLib
    .lookup<NativeFunction<Uint32 Function()>>('debugStateMachineCount')
    .asFunction();
// ignore: unused_element
final int Function() _debugAnimationCount = nativeLib
    .lookup<NativeFunction<Uint32 Function()>>('debugAnimationCount')
    .asFunction();
final int Function() _debugViewModelRuntimeCount = nativeLib
    .lookup<NativeFunction<Uint32 Function()>>('debugViewModelRuntimeCount')
    .asFunction();
final int Function() _debugViewModelInstanceRuntimeCount = nativeLib
    .lookup<NativeFunction<Uint32 Function()>>(
        'debugViewModelInstanceRuntimeCount')
    .asFunction();
final int Function() _debugViewModelInstanceValueRuntimeCount = nativeLib
    .lookup<NativeFunction<Uint32 Function()>>(
        'debugViewModelInstanceValueRuntimeCount')
    .asFunction();
final int Function() _debugYogaNodeCount = nativeLib
    .lookup<NativeFunction<Uint32 Function()>>('debugYogaNodeCount')
    .asFunction();
final int Function() _debugBindableArtboardCount = nativeLib
    .lookup<NativeFunction<Uint32 Function()>>('debugBindableArtboardCount')
    .asFunction();

void main() {
  test('can load a rive file', () async {
    expect(_debugFileCount(), 0);
    final file = File('test/assets/tree_loading_bar.riv');
    final bytes = await file.readAsBytes();
    var riveFile =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(riveFile, isNotNull);
    expect(_debugFileCount(), 1);

    riveFile?.dispose();
    expect(_debugFileCount(), 0);
  });

  test('file lives with artboard', () async {
    expect(_debugFileCount(), 0);
    final file = File('test/assets/tree_loading_bar.riv');
    final bytes = await file.readAsBytes();
    var riveFile =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(riveFile, isNotNull);
    expect(_debugFileCount(), 1);

    final artboard = riveFile?.defaultArtboard();
    expect(artboard, isNotNull);
    expect(_debugArtboardCount(), 1);

    // Dispose the file
    riveFile?.dispose();

    // Expect native to still hold onto the file as we still have an artboard
    // that references it.
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);

    // Dispose the artboard and the expect the file to finally be deleted.
    artboard?.dispose();
    expect(_debugArtboardCount(), 0);
    expect(_debugFileCount(), 0);
  });

  test('file dies when all artboard instances die', () async {
    expect(_debugFileCount(), 0);
    final file = File('test/assets/tree_loading_bar.riv');
    final bytes = await file.readAsBytes();
    var riveFile =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(riveFile, isNotNull);
    expect(_debugFileCount(), 1);

    final artboardA = riveFile?.defaultArtboard();
    expect(artboardA, isNotNull);
    expect(_debugArtboardCount(), 1);

    final artboardB = riveFile?.defaultArtboard();
    expect(artboardB, isNotNull);
    expect(_debugArtboardCount(), 2);

    // Dispose the file
    riveFile?.dispose();

    // Expect native to still hold onto the file as we still have 2 artboards
    // that reference it.
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 2);

    // Dispose artboareA, file should live on as there's still ArtboardB reffing
    // it.
    artboardA?.dispose();
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);

    // Dispose artboareA, file should live on as there's still ArtboardB reffing
    // it.
    artboardB?.dispose();
    expect(_debugFileCount(), 0);
    expect(_debugArtboardCount(), 0);
  });

  test('file lives on with state machine', () async {
    expect(_debugFileCount(), 0);
    final file = File('test/assets/tree_loading_bar.riv');
    final bytes = await file.readAsBytes();
    var riveFile =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(riveFile, isNotNull);
    expect(_debugFileCount(), 1);

    final artboard = riveFile?.defaultArtboard();
    expect(artboard, isNotNull);

    final stateMachine = artboard?.stateMachine('Loading');
    expect(stateMachine, isNotNull);
    expect(_debugStateMachineCount(), 1);

    // Dispose the file
    riveFile?.dispose();

    // Expect native to still hold onto the file as we still have an artboard
    // and a stateMachine that reference it.
    expect(_debugFileCount(), 1);
    expect(_debugStateMachineCount(), 1);

    // Dispose the artboard and state machine and expect the file to finally be
    // deleted.
    artboard?.dispose();
    expect(_debugStateMachineCount(), 1);
    stateMachine?.dispose();
    expect(_debugFileCount(), 0);
    expect(_debugStateMachineCount(), 0);
  });

  test('file lives on with state machine', () async {
    expect(_debugFileCount(), 0);
    final file = File('test/assets/tree_loading_bar.riv');
    final bytes = await file.readAsBytes();
    var riveFile =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(riveFile, isNotNull);

    final artboard = riveFile?.defaultArtboard();
    expect(artboard, isNotNull);

    final stateMachine = artboard?.stateMachine('Loading');
    expect(stateMachine, isNotNull);
    rive.NumberInput? progress = stateMachine?.number('Progress');
    expect(progress, isNotNull);
    rive.BooleanInput? downloading = stateMachine?.boolean('Downloading');
    expect(downloading, isNotNull);

    expect(progress?.value, 0.0);
    expect(downloading?.value, true);
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);
    expect(_debugStateMachineCount(), 1);

    stateMachine?.dispose();
    artboard?.dispose();
    riveFile?.dispose();

    // They're all still held on to from native as an input is still reffing
    // them.
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);
    expect(_debugStateMachineCount(), 1);

    // Input is still around and can be set without throwing an exception
    // (because underlying artboard and state machine are still around in
    // native).
    progress?.value = 24;
    expect(progress?.value, 24);

    progress?.dispose();
    // Downloading input still hangs on:
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);
    expect(_debugStateMachineCount(), 1);

    downloading?.dispose();
    // They finally clean up.
    expect(_debugFileCount(), 0);
    expect(_debugArtboardCount(), 0);
    expect(_debugStateMachineCount(), 0);
  });

  test('file lives on with nested inputs referenced', () async {
    expect(_debugFileCount(), 0);
    final file = File('test/assets/runtime_nested_inputs.riv');
    final bytes = await file.readAsBytes();
    var riveFile =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(riveFile, isNotNull);

    final artboard = riveFile?.defaultArtboard();
    expect(artboard, isNotNull);

    final stateMachine = artboard?.defaultStateMachine();
    expect(stateMachine, isNotNull);
    rive.BooleanInput? outer =
        stateMachine?.boolean('CircleOuterState', path: 'CircleOuter');
    expect(outer, isNotNull);
    rive.BooleanInput? inner = stateMachine?.boolean('CircleInnerState',
        path: 'CircleOuter/CircleInner');

    // All should still be active, as nothing is dipsosed.
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);
    expect(_debugStateMachineCount(), 1);

    stateMachine?.dispose();
    artboard?.dispose();
    riveFile?.dispose();

    // They should still be held on to as both inputs are still around.
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);
    expect(_debugStateMachineCount(), 1);

    expect(outer?.value, false);
    outer?.value = true;
    expect(outer?.value, true);
    expect(inner?.value, false);
    inner?.value = true;
    expect(inner?.value, true);

    outer?.dispose();

    // They should still be held on to as [inner] input is still around.
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);
    expect(_debugStateMachineCount(), 1);

    inner?.dispose();

    // They should finally be cleaned up.
    expect(_debugFileCount(), 0);
    expect(_debugArtboardCount(), 0);
    expect(_debugStateMachineCount(), 0);
  });

  test('components delete correctly', () async {
    expect(_debugFileCount(), 0);
    final file = File('test/assets/rigging_a_character.riv');
    final bytes = await file.readAsBytes();
    var riveFile =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);

    final artboard = riveFile?.defaultArtboard();
    expect(artboard, isNotNull);
    expect(riveFile, isNotNull);
    riveFile?.dispose();

    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);

    final hips = artboard?.component('Hips');
    expect(hips, isNotNull);
    expect(hips?.x, 19.19441032409668);

    artboard?.dispose();

    // Even though the artboard has been disposed, native should still hold on
    // to it as we have a ref to a component.
    expect(hips?.x, 19.19441032409668);
    expect(_debugArtboardCount(), 1);
    expect(_debugFileCount(), 1);

    hips?.dispose();

    expect(_debugArtboardCount(), 0);
    expect(_debugFileCount(), 0);
  });

  test('file lives on with a reference to an event', () async {
    expect(_debugFileCount(), 0);
    final file = File('test/assets/events_test.riv');
    final bytes = await file.readAsBytes();
    var riveFile =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(riveFile, isNotNull);

    final artboard = riveFile?.defaultArtboard();
    expect(artboard, isNotNull);

    final stateMachine = artboard?.defaultStateMachine();
    expect(stateMachine, isNotNull);

    rive.Event? observedEvent;

    eventCallback(rive.Event event) {
      observedEvent = event;
    }

    stateMachine!.addEventListener(eventCallback);
    final trigger = stateMachine.trigger('FireGeneralEvent');
    trigger!.fire();
    // This advance processes the fire but because we internally grab the latest events
    // before advancing the artboard, we don't catch "this frame's" events until the next
    // advance, which is why we advance twice here.
    stateMachine.advanceAndApply(0.016);
    stateMachine.advanceAndApply(0.016);
    expect(observedEvent, isNotNull);

    expect(stateMachine.eventListenerCount, 1);
    stateMachine.removeEventListener(eventCallback);
    expect(stateMachine.eventListenerCount, 0);

    // All should still be active, as nothing is dipsosed.
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);
    expect(_debugStateMachineCount(), 1);

    stateMachine.dispose();
    artboard?.dispose();
    riveFile?.dispose();
    trigger.dispose();

    // They should still be held on to as the event is still around.
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);
    expect(_debugStateMachineCount(), 1);

    observedEvent?.dispose();

    // They should finally be cleaned up.
    expect(_debugFileCount(), 0);
    expect(_debugArtboardCount(), 0);
    expect(_debugStateMachineCount(), 0);
  });

  test(
    'audio events do not keep the file alive',
    () async {
      expect(_debugFileCount(), 0);
      final file = File('test/assets/audio_event_test.riv');
      final bytes = await file.readAsBytes();
      var riveFile =
          await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
      expect(riveFile, isNotNull);

      final artboard = riveFile?.defaultArtboard();
      expect(artboard, isNotNull);

      final stateMachine = artboard?.defaultStateMachine();
      expect(stateMachine, isNotNull);

      expect(_debugFileCount(), 1);
      expect(_debugArtboardCount(), 1);
      expect(_debugStateMachineCount(), 1);

      void eventListener(rive.Event event) {}

      stateMachine?.addEventListener(eventListener);

      stateMachine?.advanceAndApply(0.016);
      stateMachine?.advanceAndApply(0.016);

      expect(stateMachine?.eventListenerCount, 1);

      final trigger = stateMachine?.trigger('playAudio');
      expect(trigger, isNotNull);
      trigger?.fire();

      stateMachine?.advanceAndApply(0.016);
      stateMachine?.advanceAndApply(0.016);
      stateMachine?.advanceAndApply(0.016);
      stateMachine?.advanceAndApply(0.016);

      trigger?.dispose();

      stateMachine?.dispose();
      artboard?.dispose();
      riveFile?.dispose();

      expect(_debugFileCount(), 0);
      expect(_debugArtboardCount(), 0);
      expect(_debugStateMachineCount(), 0);
    },
  );

  test('file lives on with a reference to an event custom property', () async {
    expect(_debugFileCount(), 0);
    final file = File('test/assets/events_test.riv');
    final bytes = await file.readAsBytes();
    var riveFile =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(riveFile, isNotNull);

    final artboard = riveFile?.defaultArtboard();
    expect(artboard, isNotNull);

    final stateMachine = artboard?.defaultStateMachine();
    expect(stateMachine, isNotNull);

    rive.Event? observedEvent;
    rive.CustomNumberProperty? customNumber;
    rive.CustomBooleanProperty? customBoolean;
    rive.CustomStringProperty? customString;

    eventCallback(rive.Event event) {
      observedEvent = event;
      customNumber = event.numberProperty('SomeNumber');
      customBoolean = event.booleanProperty('SomeBoolean');
      customString = event.stringProperty('SomeString');
    }

    stateMachine!.addEventListener(eventCallback);
    final trigger = stateMachine.trigger('FireGeneralEvent');
    trigger!.fire();
    // This advance processes the fire but because we internally grab the latest events
    // before advancing the artboard, we don't catch "this frame's" events until the next
    // advance, which is why we advance twice here.
    stateMachine.advanceAndApply(0.016);
    stateMachine.advanceAndApply(0.016);
    expect(observedEvent, isNotNull);

    expect(stateMachine.eventListenerCount, 1);
    stateMachine.removeEventListener(eventCallback);
    expect(stateMachine.eventListenerCount, 0);

    expect(customNumber, isNotNull);
    expect(customBoolean, isNotNull);
    expect(customString, isNotNull);

    // All should still be active, as nothing is dipsosed.
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);
    expect(_debugStateMachineCount(), 1);

    stateMachine.dispose();
    artboard?.dispose();
    riveFile?.dispose();
    trigger.dispose();

    // They should still be held on to as the event is still around.
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);
    expect(_debugStateMachineCount(), 1);

    observedEvent?.dispose();

    // They should still be held on to as there are custom properties around
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);
    expect(_debugStateMachineCount(), 1);

    customNumber?.dispose();
    customBoolean?.dispose();

    // One custom property is still alive...
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);
    expect(_debugStateMachineCount(), 1);

    customString?.dispose();

    // They should finally be cleaned up.
    expect(_debugFileCount(), 0);
    expect(_debugArtboardCount(), 0);
    expect(_debugStateMachineCount(), 0);
  });

  test('FileAsset live on after file is disposed', () async {
    expect(_debugFileCount(), 0);
    final file = File('test/assets/out_of_band.riv');
    final bytes = await file.readAsBytes();
    List<rive.ImageAsset> imageAssets = [];
    List<rive.FontAsset> fontAssets = [];
    List<rive.AudioAsset> audioAssets = [];

    var riveFile = await rive.File.decode(
      bytes,
      riveFactory: rive.Factory.flutter,
      assetLoader: (fileAsset, bytes) {
        switch (fileAsset) {
          case rive.ImageAsset imageAsset:
            imageAssets.add(imageAsset);
            break;
          case rive.FontAsset fontAsset:
            fontAssets.add(fontAsset);
            break;
          case rive.AudioAsset audioAsset:
            audioAssets.add(audioAsset);
            break;
          case rive.UnknownAsset _:
            break;
        }
        return true;
      },
    );
    expect(riveFile, isNotNull);
    expect(imageAssets.length, 3);
    expect(fontAssets.length, 3);
    expect(audioAssets.length, 3);
    expect(_debugFileCount(), 1);

    // Assets should remain alive after the file is disposed
    riveFile?.dispose();
    expect(_debugFileCount(), 0);

    // Validate assets are still around
    expect(imageAssets[0].assetId, 2929282);
    expect(imageAssets[1].assetId, 2929283);
    expect(imageAssets[2].assetId, 2989123);
    expect(fontAssets[0].assetId, 594377);
    expect(fontAssets[1].assetId, 593562);
    expect(fontAssets[2].assetId, 593587);
    expect(audioAssets[0].assetId, 2929275);
    expect(audioAssets[1].assetId, 2929340);
    expect(audioAssets[2].assetId, 2989208);

    final riveFactory = rive.Factory.flutter;

    // Decode font
    final fontFile = File('test/assets/fonts/Inter-594377.ttf');
    final fontBytes = await fontFile.readAsBytes();
    final font = await riveFactory.decodeFont(fontBytes);

    // Audio
    final audioFile = File('test/assets/audio/referenced_audio-2929340.wav');
    final audioBytes = await audioFile.readAsBytes();
    final audio = await riveFactory.decodeAudio(audioBytes);

    // Image
    final imageFile = File('test/assets/images/referenced-image-2929282.png');
    final imageBytes = await imageFile.readAsBytes();
    final image = await riveFactory.decodeImage(imageBytes);

    // File is disposed, assets should still be accessible
    expect(imageAssets[0].renderImage(image!), true);
    expect(fontAssets[0].font(font!), true);
    expect(audioAssets[0].audio(audio!), true);

    // Dispose assets
    imageAssets[0].dispose();
    imageAssets[1].dispose();
    imageAssets[2].dispose();
    fontAssets[0].dispose();
    fontAssets[1].dispose();
    fontAssets[2].dispose();
    audioAssets[0].dispose();
    audioAssets[1].dispose();
    audioAssets[2].dispose();

    // Asset should be diposed
    expect(imageAssets[0].assetId, 0);
    expect(imageAssets[1].assetId, 0);
    expect(imageAssets[2].assetId, 0);
    expect(fontAssets[0].assetId, 0);
    expect(fontAssets[1].assetId, 0);
    expect(fontAssets[2].assetId, 0);
    expect(audioAssets[0].assetId, 0);
    expect(audioAssets[1].assetId, 0);
    expect(audioAssets[2].assetId, 0);

    expect(_debugFileCount(), 0); // should still be 0
  });

  test('View Model lives on when Rive file is disposed', () async {
    expect(_debugFileCount(), 0);
    final file = File('test/assets/databinding.riv');
    final bytes = await file.readAsBytes();
    var riveFile =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    var artboard = riveFile!.defaultArtboard();
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);

    expect(_debugViewModelRuntimeCount(), 0);
    final viewModelByName = riveFile.viewModelByName('Person');
    final viewModelDefault = riveFile.defaultArtboardViewModel(artboard!);
    final viewModelByIndex = riveFile.viewModelByIndex(0);
    expect(_debugViewModelRuntimeCount(), 3);

    artboard.dispose();
    riveFile.dispose();

    /// The reference to the view model should keep the file alive
    expect(_debugFileCount(), 1);

    /// But not the artboard
    expect(_debugArtboardCount(), 0);

    /// All view models should still be alive
    expect(_debugViewModelRuntimeCount(), 3);

    // Dispose one view model
    viewModelByIndex!.dispose();

    /// Only two view models should still be alive
    expect(_debugViewModelRuntimeCount(), 2);

    viewModelByName!.dispose();

    /// Only one view model should still be alive
    /// which should still keep the file alive
    expect(_debugViewModelRuntimeCount(), 1);
    expect(_debugFileCount(), 1);

    /// No view model instances
    expect(_debugViewModelInstanceRuntimeCount(), 0);

    var nulVMI = viewModelByName.createInstanceByName('Gordon');

    /// Trying to create an instance from a diposed view model should return null
    expect(nulVMI, null);

    /// Instance count should still be zero
    expect(_debugViewModelInstanceRuntimeCount(), 0);

    var vmiFromName = viewModelDefault!.createInstanceByName('Gordon');
    expect(vmiFromName, isNotNull);
    expect(_debugViewModelInstanceRuntimeCount(), 1);

    /// Access a number property works
    expect(vmiFromName, isNotNull);
    var ageProperty = vmiFromName!.number('age');
    expect(ageProperty, isNotNull);
    expect(ageProperty!.value, 30);
    expect(_debugViewModelInstanceValueRuntimeCount(), 1);

    var vmiDefault = viewModelDefault.createDefaultInstance();
    var vmiIndex = viewModelDefault.createInstanceByIndex(0);

    /// Increase/decrease vmi runtime count
    expect(_debugViewModelInstanceRuntimeCount(), 3);
    vmiDefault!.dispose();
    vmiIndex!.dispose();
    expect(_debugViewModelInstanceRuntimeCount(), 1);

    /// Disposing the last view model should now delete the file and view model
    viewModelDefault.dispose();
    expect(_debugFileCount(), 0);
    expect(_debugViewModelRuntimeCount(), 0);

    /// The `vmiPerson` should still be alive. This is not
    /// tied to the file or the view model. And can be reasigned to a different
    /// view model on a different file.
    expect(_debugViewModelInstanceRuntimeCount(), 1);

    /// The `ageProperty` should still be alive
    expect(_debugViewModelInstanceValueRuntimeCount(), 1);

    /// Access other properties
    var stringProperty = vmiFromName.string('name');
    expect(stringProperty, isNotNull);
    var colorProperty = vmiFromName.color('favourite_color');
    expect(colorProperty, isNotNull);
    var booleanProperty = vmiFromName.boolean('likes_popcorn');
    expect(booleanProperty, isNotNull);
    var enumProperty = vmiFromName.enumerator('favourite_pet');
    expect(enumProperty, isNotNull);

    // Runtime property instance count should now be five
    expect(_debugViewModelInstanceValueRuntimeCount(), 5);

    // Accessing a view model should not increase the value count
    // but increase the instance runtime count
    var viewModelProperty = vmiFromName.viewModel('pet');
    expect(_debugViewModelInstanceValueRuntimeCount(), 5);
    expect(_debugViewModelInstanceRuntimeCount(), 2);

    viewModelProperty!.dispose();
    expect(_debugViewModelInstanceRuntimeCount(), 1);

    /// Accessing by path should increase the value count but not
    /// the view model instance count
    var petType = vmiFromName.enumerator('pet/type');
    expect(_debugViewModelInstanceValueRuntimeCount(), 6);
    expect(_debugViewModelInstanceRuntimeCount(), 1);

    /// Runtime property instance count should now be one after disposing
    /// all but one property
    petType!.dispose();
    stringProperty!.dispose();
    colorProperty!.dispose();
    booleanProperty!.dispose();
    enumProperty!.dispose();
    expect(_debugViewModelInstanceValueRuntimeCount(), 1);

    vmiFromName.dispose();

    /// This should still be alive as there is a property that
    /// references the view model instance
    expect(_debugViewModelInstanceRuntimeCount(), 1);

    /// `ageProperty` should still be accessible
    expect(ageProperty.value, 30);
    ageProperty.dispose();

    // All properties and view model instances are disposed. Should be 0
    expect(_debugViewModelInstanceRuntimeCount(), 0);

    /// This should return null as the view model instance is disposed
    var nullProp = vmiDefault.number('age');
    expect(nullProp, isNull);

    // Everything should be null
    expect(_debugFileCount(), 0);
    expect(_debugArtboardCount(), 0);
    expect(_debugViewModelRuntimeCount(), 0);
    expect(_debugViewModelInstanceRuntimeCount(), 0);
    expect(_debugViewModelInstanceValueRuntimeCount(), 0);
  });

  test('yoga nodes destroy as expected', () async {
    if (!_builtWithRiveTools()) {
      return;
    }
    final layoutNode = LayoutNode.make();
    expect(_debugYogaNodeCount(), 1);
    final layoutNode2 = LayoutNode.make();
    expect(_debugYogaNodeCount(), 2);
    layoutNode.dispose();
    layoutNode2.dispose();
    expect(_debugYogaNodeCount(), 0);

    final file = File('test/assets/tree_loading_bar.riv');
    final bytes = await file.readAsBytes();
    var riveFile =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(riveFile, isNotNull);
    expect(_debugFileCount(), 1);

    {
      final artboardA = riveFile?.defaultArtboard();
      expect(artboardA, isNotNull);
      expect(_debugArtboardCount(), 1);
      expect(_debugYogaNodeCount(), 2);
      artboardA?.dispose();

      // One more owned by artboard in file
      expect(_debugYogaNodeCount(), 1);
    }

    {
      final artboardA = riveFile?.defaultArtboard();
      expect(artboardA, isNotNull);
      expect(_debugArtboardCount(), 1);
      expect(_debugYogaNodeCount(), 2);
      final layout = LayoutNode.fromExternal(artboardA?.takeLayoutNode());
      final layoutNodeHost = LayoutNode.make();
      expect(_debugYogaNodeCount(), 3);
      layoutNodeHost.insertChild(layout, 0);
      expect(_debugYogaNodeCount(), 3);
      artboardA?.dispose();
      layout.dispose();
      expect(_debugYogaNodeCount(), 3);
      riveFile?.dispose();
      // File artboard gets disposed since no artboard or file remains, but
      // layout nodes do.
      expect(_debugYogaNodeCount(), 2);

      // Expected to not crash
      layoutNodeHost.calculateLayout(100, 100, LayoutDirection.ltr);
      layoutNodeHost.dispose();
      expect(_debugYogaNodeCount(), 0);
    }
  });

  test('BindableArtboard lives on when Rive File is disposed', () async {
    expect(_debugFileCount(), 0);
    final file = File('test/assets/artboard_db_test.riv');
    final bytes = await file.readAsBytes();
    var riveFile =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(riveFile, isNotNull);
    expect(_debugFileCount(), 1);

    final artboardRed = riveFile?.artboardToBind('ArtboardRed');
    final artboardBlue = riveFile?.artboardToBind('ArtboardRed');
    final artboardGreen = riveFile?.artboardToBind('ArtboardRed');
    expect(artboardRed, isNotNull);
    expect(artboardBlue, isNotNull);
    expect(artboardGreen, isNotNull);

    expect(_debugBindableArtboardCount(), 3);

    // Dispose the file
    riveFile?.dispose();

    // Expect native to still hold onto the file as we still have BindableArtboards
    expect(_debugFileCount(), 1);
    expect(_debugBindableArtboardCount(), 3);

    // Dispose the artboard and state machine and expect the file to finally be
    // deleted.
    artboardRed?.dispose();
    expect(_debugBindableArtboardCount(), 2);
    expect(_debugFileCount(), 1);
    artboardBlue?.dispose();
    expect(_debugBindableArtboardCount(), 1);
    expect(_debugFileCount(), 1);
    artboardGreen?.dispose();
    expect(_debugBindableArtboardCount(), 0);
    expect(_debugFileCount(), 0);
  });

  test('file and artboard live on with text runs referenced', () async {
    expect(_debugFileCount(), 0);
    expect(_debugArtboardCount(), 0);

    final file = File('test/assets/get_all_text_runs_test.riv');
    final bytes = await file.readAsBytes();
    var riveFile =
        await rive.File.decode(bytes, riveFactory: rive.Factory.flutter);
    expect(riveFile, isNotNull);
    expect(_debugFileCount(), 1);

    final artboard = riveFile?.defaultArtboard();
    expect(artboard, isNotNull);
    expect(_debugArtboardCount(), 1);

    // Get all text runs
    final textRuns = artboard!.textRuns;
    expect(textRuns.length, 10);

    // Verify initial state
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);

    // Dispose the file and artboard
    riveFile?.dispose();
    artboard.dispose();

    // File and artboard should still be alive because text runs reference them
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);

    // Text runs should still be accessible
    final firstTextRun = textRuns.firstWhere((tr) => tr.name == 'Run 1 name');
    expect(firstTextRun.text, 'run 1 value');

    // Can still modify text runs
    firstTextRun.text = 'modified value';
    expect(firstTextRun.text, 'modified value');

    // Dispose all but one text run
    for (int i = 0; i < textRuns.length - 1; i++) {
      textRuns[i].dispose();
    }

    // File and artboard should still be alive because one text run remains
    expect(_debugFileCount(), 1);
    expect(_debugArtboardCount(), 1);

    // Last text run should still be accessible
    final lastTextRun = textRuns.last;
    expect(lastTextRun.name, isNotEmpty);

    // Dispose the last text run
    lastTextRun.dispose();

    // Now file and artboard should finally be cleaned up
    expect(_debugFileCount(), 0);
    expect(_debugArtboardCount(), 0);
  });
}
