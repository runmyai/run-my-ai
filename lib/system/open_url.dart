import 'dart:io';

/// Opens [url] in the computer's default browser. Returns whether the system's opener accepted it; it never throws
/// (a computer with no opener installed just gets false). Only web addresses are opened.
Future<bool> openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return false;
  final (program, arguments) = switch (Platform.operatingSystem) {
    'windows' => ('rundll32', ['url.dll,FileProtocolHandler', url]),
    'macos' => ('open', [url]),
    _ => ('xdg-open', [url]),
  };
  try {
    final result = await Process.run(program, arguments);
    return result.exitCode == 0;
  } on Object catch (_) {
    return false;
  }
}
