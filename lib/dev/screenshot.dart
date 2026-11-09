import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Developer-only screenshots, switched on by environment variables (never set in normal use):
///   RUNMYAI_SCREENSHOT=file.png     save the first screen to this file, then quit
///   RUNMYAI_THEME=light|dark|dark2|dark3  force a theme (default: the user's choice)
///   RUNMYAI_SECTION=chat|code|store|settings
///   RUNMYAI_LOOK=mac|windows|linux  draw another system's window look (lib/window/app_window.dart)
final String? screenshotPath = Platform.environment['RUNMYAI_SCREENSHOT'];
final String? forcedTheme = Platform.environment['RUNMYAI_THEME'];
final String? forcedSection = Platform.environment['RUNMYAI_SECTION'];

final screenshotKey = GlobalKey();

void scheduleScreenshot() {
  final path = screenshotPath;
  if (path == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    // Give the logo images time to load before capturing.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await saveScreenshot(path);
    exit(0);
  });
}

/// Saves what the app shows now to [path] (also used by the click-through test).
Future<void> saveScreenshot(String path) async {
  final boundary = screenshotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final ratio = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
  final image = await boundary.toImage(pixelRatio: ratio);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(path).writeAsBytes(bytes!.buffer.asUint8List());
}
