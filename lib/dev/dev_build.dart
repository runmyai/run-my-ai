/// The developer's build (`flutter run --dart-define=RMAI_DEV=true`): shows the features kept out of the shipped app
/// (the other themes, reply motion, the speed's look, the stand-in model's speed control).
const devBuild = bool.fromEnvironment('RMAI_DEV');
