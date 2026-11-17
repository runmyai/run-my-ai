import 'dart:io';

/// Starts a new copy of the app (with the same environment) and ends this one: for a change that the running app
/// cannot take over, such as the chats folder moving while its files are open.
Future<Never> relaunchApp() async {
  await Process.start(Platform.resolvedExecutable, Platform.executableArguments, mode: ProcessStartMode.detached);
  exit(0);
}
