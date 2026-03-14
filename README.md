# flutter_mock_server

A Flutter-focused local mock API server that reads routes from `mock.yaml` and serves predictable responses for app development.

## Features

- `flutter_mock init` creates a starter `mock.yaml` and `data/` folder.
- `flutter_mock start` runs a local server on `http://localhost:8080` by default.
- `flutter_mock validate` checks YAML syntax and schema.
- Supports `GET`, `POST`, `PUT`, and `DELETE` routes.
- Serves inline bodies or JSON payloads from files.
- Expands template fields such as `{{uuid}}`, `{{name}}`, and `{{timestamp}}`.
- Supports optional delays and probabilistic error responses.
- Reloads configuration automatically when `mock.yaml` changes.

## Installation

```bash
dart pub global activate flutter_mock_server
```

Or run it directly from the package:

```bash
dart run flutter_mock_server start
```

## Commands

### Initialize a project

```bash
flutter_mock init
```

### Start the server

```bash
flutter_mock start
```

Options:

```text
--config   Path to the YAML config file. Defaults to mock.yaml.
--host     Host interface to bind. Defaults to localhost.
--port     Port to bind. Defaults to 8080.
```

### Validate configuration

```bash
flutter_mock validate
```

## Configuration

Basic route configuration:

```yaml
routes:
  - path: /users
    method: GET
    response:
      file: data/users.json

  - path: /users
    method: POST
    response:
      status: 201
      body:
        message: User created
        id: "{{uuid}}"
```

Advanced response options:

```yaml
routes:
  - path: /users
    method: GET
    response:
      delay_ms: 250
      headers:
        x-mock-source: flutter_mock_server
      file: data/users.json
      error:
        rate: 0.2
        status: 503
        body:
          message: Temporary mock failure
          retryAt: "{{timestamp}}"
```

Supported template fields:

- `{{uuid}}`
- `{{name}}`
- `{{timestamp}}`

## Development

```bash
dart pub get
dart analyze
dart run flutter_mock_server validate
dart run flutter_mock_server start
```

## Release Flow

- All changes to `main` are expected to go through pull requests.
- Every pull request to `main` must increment `pubspec.yaml` version.
- Pull requests opened by contributors other than `@NJashwanth` require approval from `@NJashwanth` before merge.
- When a change lands on `main`, GitHub Actions creates a matching `v<version>` tag from `pubspec.yaml`.
- Pushing that tag triggers automated publication to pub.dev.

### pub.dev trusted publishing

To make `Publish to pub.dev` work, configure this GitHub repository as a trusted publisher for the package on pub.dev. The workflow uses GitHub Actions OIDC via `id-token: write`, so no long-lived pub token is required once trusted publishing is configured.

## Package layout

```text
flutter_mock_server/
├── bin/flutter_mock.dart
├── bin/flutter_mock_server.dart
├── lib/cli/
├── lib/config/yaml_parser.dart
├── lib/server/
├── lib/utils/template_engine.dart
├── example/
├── mock.yaml
├── data/
├── pubspec.yaml
└── README.md
```
