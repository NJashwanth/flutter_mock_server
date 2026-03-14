# Changelog

## 0.1.1

- Initial public release of `flutter_mock_server`.
- Added CLI commands for `init`, `start`, and `validate`.
- Added YAML-driven route configuration through `mock.yaml`.
- Added Shelf-based local mock server support for `GET`, `POST`, `PUT`, and `DELETE` routes.
- Added inline response bodies and file-based JSON responses from `data/*.json`.
- Added dynamic response templates for `{{uuid}}`, `{{name}}`, and `{{timestamp}}`.
- Added optional response delays and simulated error responses.
- Added hot reload when `mock.yaml` changes.