// The release source switch: RUNMYAI_GITHUB_API replaces GitHub's API address.
// Run: flutter test test/github_api_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/engine/engine_download.dart';
import 'package:runmyai/system/github.dart';

void main() {
  test('unset: GitHub itself', () {
    expect(gitHubApi({}), Uri.parse('https://api.github.com'));
    expect(
      gitHubApi({}).resolve('/repos/runmyai/tokenwing/releases/latest').toString(),
      'https://api.github.com/repos/runmyai/tokenwing/releases/latest',
    );
  });

  test('set: the given server, with the same paths', () {
    final api = gitHubApi({'RUNMYAI_GITHUB_API': 'http://127.0.0.1:8765'});
    expect(
      api.resolve('/repos/runmyai/tokenwing/releases/latest').toString(),
      'http://127.0.0.1:8765/repos/runmyai/tokenwing/releases/latest',
    );
  });

  test('the engine release address follows the process environment (unset here)', () {
    expect(engineReleases.host, 'api.github.com');
  });
}
