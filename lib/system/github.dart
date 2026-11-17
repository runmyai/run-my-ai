import 'dart:io';

/// GitHub's API; RUNMYAI_GITHUB_API replaces it so a release can be tested from a local server ([env] is for tests).
Uri gitHubApi([Map<String, String>? env]) =>
    Uri.parse((env ?? Platform.environment)['RUNMYAI_GITHUB_API'] ?? 'https://api.github.com');
