# Changelog

## 1.0.0

- Added schema-driven models for deterministic fake data generation.
- Added seeded in-memory stores for stateful API mocking.
- Added CRUD route actions with path parameter matching.
- Added request-aware templating for path, query, and body bindings.
- Added list filtering, sorting, and pagination through query parameters.
- Added richer model fields for explicit arrays, nested schemas, and ranged dates.
- Added automated tests covering CRUD flows, filtering, request bindings, and generated field types.
- Updated the CLI starter config, examples, and docs to reflect the new workflow.

## 0.1.6

- Updated CI/CD workflow for pub.dev publishing from `main`, including existing-version checks and credential restore from GitHub secret.

## 0.1.5

- Hardened publish workflow validation so push and manual dispatch events resolve refs safely without invalid workflow runs.

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