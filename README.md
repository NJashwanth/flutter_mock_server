# flutter_mock_server

A Flutter-focused local mock API server that can serve static responses or run a schema-driven, stateful API simulator for app development.

## Mental Model

`flutter_mock_server` has three main building blocks:

- `models` describe the shape of generated data.
- `stores` keep in-memory collections of generated records based on those models.
- `routes` either return static responses or perform CRUD actions against stores.

Use it in one of two ways:

- Static mode: return a fixed inline body or a JSON file.
- Stateful mode: define models and stores, then let routes create, read, update, list, and delete records.

Important behavior:

- Store data is in memory only.
- Restarting the server or reloading `mock.yaml` rebuilds stores from the configured seed.
- If a `seed` is provided, generated records are deterministic across reloads.

## What is new in 1.0.0

- Schema-driven models for reusable fake data definitions.
- Seeded in-memory stores so responses stay deterministic across reloads.
- CRUD actions with path parameter matching.
- Query-based filtering, sorting, and pagination for list endpoints.
- Request-aware templating with access to path params, query params, and JSON body values.
- Existing static YAML responses, delays, error injection, and hot reload still work.

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

Creates a starter `mock.yaml` that demonstrates models, stores, and CRUD routes.

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

Validation output now includes route, model, and store counts.

## Quick Start

```yaml
seed: 42

models:
  User:
    id: uuid
    name: name
    email: email
    role:
      enum: [admin, member, viewer]
    age:
      type: int
      min: 18
      max: 60

stores:
  users:
    model: User
    count: 8

routes:
  - path: /users
    method: GET
    action: list
    store: users

  - path: /users/:id
    method: GET
    action: get
    store: users

  - path: /users
    method: POST
    action: create
    store: users

  - path: /users/:id
    method: PUT
    action: update
    store: users

  - path: /users/:id
    method: DELETE
    action: delete
    store: users

  - path: /session
    method: POST
    response:
      status: 201
      body:
        token: "{{uuid}}"
        email: "{{request.body.email}}"
        message: Signed in
```

What this config does:

- seeds a `users` store with 8 generated `User` records
- exposes CRUD endpoints for `/users` and `/users/:id`
- keeps generated data stable across reloads because `seed: 42` is set
- adds a static `/session` route that reads from the incoming request body

Start the server:

```bash
flutter_mock start
```

Then try:

```bash
curl http://localhost:8080/users
curl http://localhost:8080/users?role=admin&limit=2
curl -X POST http://localhost:8080/users \
  -H "content-type: application/json" \
  -d '{"name":"Morgan","email":"morgan@sample.app","role":"member","age":29}'
```

## Configuration

### Models

A model is a reusable schema. Each field can be a built-in generator, a constrained numeric field, an enum, another model name, an explicit array schema, or a ranged date.

In practice:

- use a built-in type like `email` or `uuid` for generated values
- use another model name to nest an object
- use `type: array` with `items` to generate lists
- use `example` when you want a fixed value instead of a generated one

Supported built-in field types:

- `uuid`
- `name`
- `email`
- `timestamp`
- `date`
- `int`
- `double`
- `bool`
- `word`
- `sentence`
- `string`

Examples:

```yaml
models:
  Review:
    author: name
    createdAt:
      type: date
      from: 2026-01-01T00:00:00Z
      to: 2026-01-31T23:59:59Z
  ProductVariant:
    sku: word
    stock:
      type: int
      min: 1
      max: 20
  Product:
    id: uuid
    name: sentence
    price:
      type: double
      min: 9.99
      max: 199.99
    status:
      enum: [draft, active, archived]
    variants:
      type: array
      count: 2
      items:
        type: ProductVariant
    latestReview:
      type: Review
```

Array fields use `type: array` with `count` and an `items` definition. Date fields use `type: date` with optional `from`, `to`, and `format: date`.

### Stores

A store seeds an in-memory collection from a model.

Think of a store as a temporary local table. Routes can list records from it, fetch one by id, create new ones, update them, and delete them.

```yaml
stores:
  products:
    model: Product
    count: 25
    primary_key: id
```

### CRUD Actions

A route becomes stateful when it uses `action` and `store`.

Supported actions:

- `list`
- `get`
- `create`
- `update`
- `delete`

Path parameters use `:paramName` syntax.

```yaml
routes:
  - path: /products
    method: GET
    action: list
    store: products

  - path: /products/:id
    method: GET
    action: get
    store: products
```

Typical behavior:

- `list` returns an array of records
- `get` returns a single record matched by the route parameter
- `create` merges generated model values with the JSON request body
- `update` patches an existing record with the JSON request body
- `delete` removes the record and returns a confirmation payload

Example flow:

```bash
curl -X POST http://localhost:8080/users \
  -H "content-type: application/json" \
  -d '{"name":"Morgan","email":"morgan@sample.app","role":"member","age":29}'
```

Example response:

```json
{
  "id": "a786ac22-0643-4983-81f1-884dfb30eaa1",
  "name": "Morgan",
  "email": "morgan@sample.app",
  "role": "member",
  "age": 29
}
```

Then:

```bash
curl http://localhost:8080/users/a786ac22-0643-4983-81f1-884dfb30eaa1
curl -X PUT http://localhost:8080/users/a786ac22-0643-4983-81f1-884dfb30eaa1 \
  -H "content-type: application/json" \
  -d '{"role":"admin"}'
curl -X DELETE http://localhost:8080/users/a786ac22-0643-4983-81f1-884dfb30eaa1
```

### Query Behavior

List routes support:

- exact-match filtering with arbitrary query params such as `?role=admin`
- sorting with `?sort=name&order=asc`
- pagination with `?page=2&limit=20`

### Request-Aware Templates

Templates can read data from the request and the current record.

Supported placeholders include:

- `{{uuid}}`
- `{{name}}`
- `{{email}}`
- `{{timestamp}}`
- `{{request.path.id}}`
- `{{request.query.role}}`
- `{{request.body.email}}`
- `{{record.name}}`

Example:

```yaml
routes:
  - path: /session
    method: POST
    response:
      status: 201
      body:
        token: "{{uuid}}"
        email: "{{request.body.email}}"
        userId: "{{request.path.id}}"
```

      These bindings are useful when you want a mostly static route to still echo request data, such as login, search, upload, or workflow endpoints.

### Static Responses Still Supported

You can continue using the original file-based or inline response mode.

      Use static mode when you just need a fixed response quickly. Use stateful mode when your app needs realistic create/edit/delete flows or data that stays consistent across requests.

```yaml
routes:
  - path: /health
    method: GET
    response:
      body:
        status: ok
        generatedAt: "{{timestamp}}"

  - path: /users
    method: GET
    response:
      file: data/users.json
```

Advanced response options still work:

- `status`
- `headers`
- `delay_ms`
- `error.rate`
- `error.status`
- `error.body`
- `error.file`

## Example

Run the end-to-end example:

```bash
dart run example/flutter_mock_server_example.dart
```

The example:

- starts a schema-driven server on a free local port
- lists seeded users with query filtering
- creates a user through `POST /users`
- reads and updates the created user through `GET` and `PUT`
- issues a request-aware static response through `POST /session`
- deletes the created user through `DELETE`

## Development

```bash
dart pub get
dart analyze
dart run flutter_mock_server validate
dart run example/flutter_mock_server_example.dart
```
