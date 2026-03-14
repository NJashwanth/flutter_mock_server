# Changelog

## 0.1.4

- Fixed the publish workflow trigger logic so tag-push CI/CD runs execute correctly under trusted publishing.

## 0.1.3

- Fixed CI/CD release flow to publish from tag refs, matching pub.dev trusted publishing requirements.
- Kept manual `workflow_dispatch` publishing available, now constrained to version tags.

## 0.1.2

- Improved the runnable example to demonstrate a full end-to-end flow.
- Example now starts the mock server, performs real HTTP requests, and shows hot reload by updating `mock.yaml` while running.

## 0.1.1

- Initial public release of `flutter_mock_server`.
- Added CLI commands for `init`, `start`, and `validate`.
- Added YAML-driven route configuration through `mock.yaml`.
- Added Shelf-based local mock server support for `GET`, `POST`, `PUT`, and `DELETE` routes.
- Added inline response bodies and file-based JSON responses from `data/*.json`.
- Added dynamic response templates for `{{uuid}}`, `{{name}}`, and `{{timestamp}}`.
- Added optional response delays and simulated error responses.
- Added hot reload when `mock.yaml` changes.