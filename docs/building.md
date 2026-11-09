# Building

Run My AI is a [Flutter](https://flutter.dev) desktop app. Use a current stable Flutter; the app is built and tested with 3.47.

```bash
git clone https://github.com/runmyai/run-my-ai
cd run-my-ai
flutter pub get
```

## Run it

```bash
flutter run -d linux      # or: -d windows
```

## Make a release build

```bash
flutter build linux --release      # or: flutter build windows --release
```

On Linux you also need the packages Flutter's Linux builds need: clang, CMake, Ninja, pkg-config and the GTK 3 development files. On Windows, Visual Studio with the "Desktop development with C++" workload. `flutter doctor` tells you what's missing.

The native sound library in `native/` is built by the same CMake step, so it needs nothing extra.

## Test it

```bash
flutter analyze
flutter test
flutter test integration_test -d linux
```
