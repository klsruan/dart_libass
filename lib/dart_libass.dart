library dart_libass;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:libass_binding/bindings.dart';
import 'package:flutter/foundation.dart';

class DartLibass {
  final List<File> fonts;
  final File defaultFont;
  final String defaultFamily;
  final File subtitle;
  final int width;
  final int height;

  late Directory temp;
  late ffi.DynamicLibrary dylib;
  late LibassBindings bindings;
  late ffi.Pointer<ASS_Library> library;
  late ffi.Pointer<ASS_Renderer> renderer;
  late ffi.Pointer<ffi.Int> changePtr;
  late ffi.Pointer<ASS_Track> track;

  DartLibass({
    required this.fonts,
    required this.defaultFont,
    required this.defaultFamily,
    required this.subtitle,
    required this.width,
    required this.height,
  });

  Future<void> init() async {
    changePtr = calloc<ffi.Int>();

    String libPath = '';
    if (Platform.isMacOS) {
      libPath = 'assets/macos/libass.9.dylib';
    } else if (Platform.isWindows) {
      libPath = 'assets/windows/libass.dll';
    } else {
      throw UnsupportedError('Plataforma não suportada');
    }

    dylib = ffi.DynamicLibrary.open(libPath);
    bindings = LibassBindings(dylib);

    library = bindings.ass_library_init();
    renderer = bindings.ass_renderer_init(library);

    temp = await Directory.systemTemp.createTemp('fonts');
    for (var font in fonts) {
      font.copySync('${temp.path}/${font.uri.pathSegments.last}');
    }

    final fontDirPath = temp.path.toNativeUtf8();
    bindings.ass_set_fonts_dir(library, fontDirPath.cast<ffi.Char>());
    calloc.free(fontDirPath);

    final defaultFontPath = defaultFont.uri.path.toNativeUtf8();
    final defaultFamilyUtf8 = defaultFamily.toNativeUtf8();

    bindings.ass_set_fonts(
      renderer,
      defaultFontPath.cast<ffi.Char>(),
      defaultFamilyUtf8.cast<ffi.Char>(),
      1,
      ffi.nullptr,
      0,
    );

    calloc.free(defaultFontPath);
    calloc.free(defaultFamilyUtf8);

    final subtitlePath = subtitle.uri.path.toNativeUtf8();
    track = bindings.ass_read_file(library, subtitlePath.cast<ffi.Char>(), ffi.nullptr);
    calloc.free(subtitlePath);
  }

  void setTrack(File subtitle) {
    final filePath = subtitle.uri.path.toNativeUtf8();
    track = bindings.ass_read_file(library, filePath.cast<ffi.Char>(), ffi.nullptr);
    calloc.free(filePath);
  }

  void dispose() {
    bindings.ass_clear_fonts(library);
    bindings.ass_renderer_done(renderer);
    bindings.ass_library_done(library);
    calloc.free(changePtr);
  }

  Future<ui.Image?> getFrame(int timestamp) async {
    bindings.ass_set_frame_size(renderer, width, height);
    final frameImage = bindings.ass_render_frame(renderer, track, timestamp, changePtr);

    if (changePtr.value == 0 || frameImage == ffi.nullptr) return null;

    final memory = Uint8List(4 * width * height);
    memory.fillRange(0, memory.length, 0);

    ffi.Pointer<ASS_Image> img = frameImage;
    while (img != ffi.nullptr) {
      final imageRef = img.ref;
      final color = imageRef.color;
      final r = (color >> 24) & 0xFF;
      final g = (color >> 16) & 0xFF;
      final b = (color >> 8) & 0xFF;
      final a = 255 - (color & 0xFF);

      for (int y = 0; y < imageRef.h; ++y) {
        for (int x = 0; x < imageRef.w; ++x) {
          final offset = y * imageRef.stride + x;
          final opacity = imageRef.bitmap.elementAt(offset).value;
          if (opacity == 0) continue;

          final listOffset = 4 * ((imageRef.dst_y + y) * width + (imageRef.dst_x + x));
          final srcOpacity = a / 255 * opacity / 255;
          final oneMinusSrc = 1.0 - srcOpacity;

          memory[listOffset + 0] =
              (memory[listOffset + 0] * oneMinusSrc + srcOpacity * r).toInt().clamp(0, 255);
          memory[listOffset + 1] =
              (memory[listOffset + 1] * oneMinusSrc + srcOpacity * g).toInt().clamp(0, 255);
          memory[listOffset + 2] =
              (memory[listOffset + 2] * oneMinusSrc + srcOpacity * b).toInt().clamp(0, 255);
          final targetAlpha = memory[listOffset + 3] + (srcOpacity * 255).toInt();
          memory[listOffset + 3] = targetAlpha.clamp(0, 255);
        }
      }

      img = imageRef.next;
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      memory,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (ui.Image img) => completer.complete(img),
    );

    return completer.future;
  }
}