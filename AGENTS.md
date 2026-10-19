# AGENTS.md

Context for AI agents working in this repository. Read this before making changes.

## 1. What this repo is

A **NestJS microservices practice project** (from a NestJS microservices course:
gateway + `products-ms` + `orders-ms` + `payments-ms` + `auth-ms`). It is **not**
a single monorepo: each folder is an **independent npm package** with its own
`package.json`, `node_modules`, `.env` and scripts. There is no root
`package.json`. Most folders are also git **submodules** (see `.gitmodules`).

**Source of truth is the code in this repo**, not the course material. If a course
lesson conflicts with the code, follow the code and flag the discrepancy.

## 2. Services at a glance

| Folder           | Role                        | Transport          | Port | Data layer                                   |
| ---------------- | --------------------------- | ------------------ | ---- | -------------------------------------------- |
| `client-gateway` | HTTP/REST entrypoint        | HTTP + NATS clients | 3000 | none                                          |
| `products-ms`    | Products microservice       | NATS               | 3001 | Prisma + **SQLite** (`file:.dev.db`)          |
| `orders-ms`      | Orders microservice         | NATS               | 3002 | Prisma + **PostgreSQL** (Docker, host 5433)   |
| `payments-ms`    | Stripe payments (hybrid)    | HTTP + NATS        | 3003 | none                                          |
| `auth-ms`        | Users / JWT auth            | NATS               | 3004 | Prisma + **MongoDB** (Docker, host 27017)     |

Gateway talks to microservices over **NATS** (`Transport.NATS`), using the token
`NATS_SERVICE` (see `client-gateway/src/config/services.ts`). This is the real
transport; ignore older notes that say TCP.

Stack: NestJS 12, TypeScript 6, Node 24, npm.

## 3. Commands (run inside the relevant package)

```bash
npm install
npm run start:dev     # nest start --watch
npm run build         # nest build
npm run lint
npm test
```

Database / Prisma (`orders-ms` uses Postgres; `products-ms` SQLite; `auth-ms` MongoDB):

```bash
docker compose up -d            # orders-ms: start local Postgres
npx prisma generate             # after any schema change
npx prisma migrate dev --name <name>
npx prisma migrate status
npx prisma db push              # only for schemaless providers (e.g. MongoDB)
```

## 4. HTTP endpoints (gateway, global prefix `/api`)

- Products: `POST /api/products`, `GET /api/products?page&limit`,
  `GET /api/products/:id`, `PATCH /api/products/:id`, `DELETE /api/products/:id`
- Orders: `POST /api/orders`, `GET /api/orders`, `GET /api/orders/:id`
  — **protected** by `AuthGuard` (needs `Authorization: Bearer <token>`)
- Auth: `POST /api/auth/register-user`, `POST /api/auth/login-user` (public),
  `GET /api/auth/get-user` (requires `Authorization: Bearer <token>`)

## 5. Microservice message patterns (`cmd`)

- Products: `create_product`, `find_all_products`, `find_one_product`,
  `update_product`, `delete_product`
- Orders: `create_order`, `find_all_orders`, `find_one_order`,
  `change_order_status`
- Auth: `auth.register.user`, `auth.login.user`, `auth.verify.user`
  (`verify.user` receives `{ token }` and returns `{ user, token }`)

Gateway uses `client.send({ cmd }, payload)`. Most methods return the raw
`Observable`; some (e.g. `find_one_product`) use `firstValueFrom` + `try/catch`
and rethrow as `RpcException`.

## 6. Conventions

- **Config**: `dotenv` + `joi`. Every service validates `process.env` at startup
  and exports a typed `envs` object from `src/config`. A missing required var
  throws `Config validation error ...`.
- **ValidationPipe** is global in **all apps** with
  `{ whitelist: true, forbidNonWhitelisted: true }`. Consequence: **any property
  not declared in the DTO produces HTTP 400** (`property X should not exist`).
  Keep gateway DTOs and microservice DTOs **in sync**.
- **Auth**: `auth-ms` owns the JWT secret and signs/verifies tokens. The gateway
  never verifies JWTs locally; its `AuthGuard` asks `auth-ms` via
  `auth.verify.user`. DTOs (`CreateUserDto`, `LoginUserDto`) are duplicated in
  `client-gateway/src/auth/dto` and `auth-ms/src/auth/dto` — keep them identical.
- **Protected routes**: `AuthModule` exports `AuthService` + `AuthGuard`. Guard is
  applied at controller level with `@UseGuards(AuthGuard)`. `OrdersController` is
  protected; `ProductsController` is intentionally **public**. To protect another
  controller, import `AuthModule` into its module and add the decorator.
  `payments-ms` exposes its own HTTP server (port 3003, not proxied by the
  gateway), so it has its own `AuthGuard` (`src/auth/guards/auth.guard.ts`) that
  verifies via NATS; it is applied **only** to
  `POST /payments/create-payment-session`. `webhook`/`success`/`cancel` stay
  public — Stripe and the browser cannot send our JWT. That guard ignores
  non-HTTP contexts (`context.getType() !== 'http'`), so internal NATS messages
  are never blocked.
- **Errors**: gateway registers `RpcCustomExceptionFilter` to map `RpcException`
  from microservices into HTTP responses.
- **Enums**: `OrderStatus` is declared in the gateway
  (`orders/enums/order.enum.ts`); `orders-ms` imports `OrderStatus` from
  `@prisma/client`.
- Match the style of surrounding files (Prettier is configured per package).

## 7. Prisma specifics — IMPORTANT

- `prisma` and `@prisma/client` are **pinned to 5.10.2**. **Do not upgrade**
  unless explicitly asked.
- Environment is **Node 24**, where **`prisma init` is broken**:
  `Error: (0 , X.isError) is not a function` (Node removed `util.isError`).
  **Workaround**: create `prisma/schema.prisma` and `.env` by hand.
  `prisma generate`, `migrate dev`, `migrate status` and `db push` work fine.
- `products-ms`: `provider = "sqlite"`, `DATABASE_URL="file:.dev.db"`.
  Uses an injectable `PrismaService` (`src/prisma.service.ts`), injected into
  `ProductsService`.
- `orders-ms`: `provider = "postgresql"`,
  `DATABASE_URL="postgresql://postgres:123456@localhost:5433/ordersdb"`.
  The model is `Order` mapped to the table `orders` (`@@map("orders")`).
  `OrdersService` **extends `PrismaClient`** and implements `OnModuleInit`
  (`$connect()` in `onModuleInit`). Do **not** import `PrismaClient` from
  `@prisma/client/extension` — that is the extension type stub and throws
  `@prisma/client did not initialize yet` at `super()`.
- `orders-ms/docker-compose.yml` runs `postgres:16` with `user: "1000:1000"` so
  the bind-mounted `./postgres` is owned by the host user, and publishes
  **host port 5433** (5432 is taken by another container).
- Because the container runs as uid 1000 but the image creates
  `/var/run/postgresql` as the `postgres` user (uid 999), the entrypoint's
  `chmod 03775 /var/run/postgresql` used to fail with
  `chmod: changing permissions of '/var/run/postgresql': Operation not permitted`.
  Fixed with a `tmpfs` mount owned by uid/gid 1000. `stop_signal: SIGINT` gives
  Postgres a clean "fast shutdown" so stop/start/down does not log
  `database system was not properly shut down`. Keep both settings.
- `auth-ms`: `provider = "mongodb"`,
  `DATABASE_URL="mongodb://localhost:27017/authms?directConnection=true"` (in
  Docker it points at `auth-db:27017`). Model `User` uses
  `id String @id @default(auto()) @map("_id") @db.ObjectId`. **MongoDB must run
  as a replica set** (even a single node) because Prisma uses transactions:
  the `auth-db` service starts `mongod --replSet rs0` and its healthcheck runs
  `rs.initiate(...)`. Use `npx prisma db push` (not `migrate dev`) for Mongo.
  Because the container is Alpine, `binaryTargets` includes
  `linux-musl-openssl-3.0.x` (same as `products-ms`).
- Prisma migrations are per service: `orders-ms` uses `migrate dev`, `auth-ms`
  uses `db push`, `products-ms` uses `migrate dev` on SQLite.
- In Docker, `orders-ms` `docker:start` uses `prisma migrate deploy` (NOT
  `migrate dev`, which is interactive and fails with
  `environment is non-interactive, which is not supported`). Use `migrate dev`
  manually only when creating migrations.
- `OrderStatus` includes `PAID` in `orders-ms/prisma/schema.prisma`, in the
  gateway enum and in `orders-ms`'s `OrderStatusList` (the Postgres enum already
  has it). Keep the three in sync; the local DB may contain PAID orders.

## 8. Critical gotcha: stale dev processes

`npm run start:dev` (`nest start --watch`) often keeps running in the
background. After changing DTOs or the Prisma schema, an **old process can still
serve stale validation**, producing misleading errors such as
`property totalAmount should not exist`. Before debugging validation issues:

```bash
ss -ltnp | grep -E '3000|3001|3002'
# or
ps -eo pid,cmd | grep -iE 'nest|dist/main'
```

Kill the stale process (or restart it) and retest. Do not "fix" code to satisfy
an error coming from a stale build.

## 9. Rules for agents

- Do keep DTOs consistent between `client-gateway` and the target microservice.
- Do run `npx prisma generate` after editing `schema.prisma`.
- Do run `npm run build` (and `npm run lint`) in the affected package after changes.
- Don't run `prisma init`.
- Don't bump pinned dependencies (Prisma 5.10.2 and friends) unless asked.
- Don't commit `.env`, `node_modules/`, `postgres/` data or `*.dev.db`.
- Don't restart or kill the user's long-running processes without asking.

## 10. Verify a change end-to-end

```bash
# in the affected package
npm run build

# start DB if needed (orders-ms), then the services
docker compose up -d
npm run start:dev

# smoke test through the gateway
curl -X POST http://localhost:3000/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"totalAmount":100,"totalItems":2}'

# auth smoke test (auth-ms + Mongo must be up: docker compose up -d nats-server auth-db auth-ms client-gateway)
curl -X POST http://localhost:3000/api/auth/register-user \
  -H 'Content-Type: application/json' \
  -d '{"name":"Faci","email":"faci@test.com","password":"123456"}'
curl -X POST http://localhost:3000/api/auth/login-user \
  -H 'Content-Type: application/json' \
  -d '{"email":"faci@test.com","password":"123456"}'
curl http://localhost:3000/api/auth/get-user \
  -H 'Authorization: Bearer <token>'
```

Smoke test completo (crea usuario aleatorio, producto, pedido y prueba auth,
products, orders y payments; requiere `curl` y `jq`):

```bash
./smoke-test.sh
```

## 11. Production Docker images (`dockerfile.prod`)

Each service has a **`dockerfile.prod`** (multi-stage: `deps` → `build` → `prod`)
and the root has **`docker-compose.prod.yml`**. This mirrors the course's section
13 reference (`products-launcher/`), with one deviation: the base image is
`node:24-alpine3.24` (the reference uses `node:21-alpine3.19`) to match this
project's Node 24.

```bash
docker compose -f docker-compose.prod.yml build
docker compose -f docker-compose.prod.yml up
```

- Prod uses **external** databases: set `AUTH_DATABASE_URL` (Mongo) and
  `ORDERS_DATABASE_URL` (Postgres) in `.env`. There are no Mongo/Postgres
  services in the prod compose.
- The prod compose has its own `name: products-launcher-prod`, so it does not
  reuse or overwrite the dev containers from `docker-compose.yml` (same
  directory). For local testing, `.env` points both DB URLs at
  `host.docker.internal` and `auth-ms`/`orders-ms` declare that `extra_hosts`.
- Images are named `${IMAGE_REGISTRY:-localhost:5000}/<service>:${IMAGE_TAG:-1.0.0}`.
  Push with `docker compose -f docker-compose.prod.yml push` (it skips
  `nats-server`). Override `IMAGE_REGISTRY` / `IMAGE_TAG` in `.env`; the default
  is the local registry from `registry/docker-compose.yml`.
- **Prisma gotcha**: run `npx prisma generate` **before** pruning. The reference
  uses `npm ci --only=production`, but that deletes `node_modules/` (including
  `node_modules/.prisma`), and the following `npx prisma generate` then has no
  local CLI (it downloads the latest Prisma). Here we do `npx prisma generate`
  (pinned 5.10.2 from devDependencies) and then `npm prune --omit=dev`, which
  keeps `.prisma`.
- `orders-ms` builds with `ARG ORDERS_DATABASE_URL` and runs
  `npx prisma migrate deploy` at **build time**, so the Postgres URL must be
  reachable from the build.
- `payments-ms` has no Prisma, so its `dockerfile.prod` has **no**
  `prisma generate` (the reference had a stray one).
- `node:24-alpine3.24` ships `libssl3`/`libcrypto3`, but Prisma 5.10.2 still
  needs the `openssl` **binary** to detect the version. Without it
  `prisma migrate deploy` fails in the build with
  `Could not parse schema engine response`, and at runtime the client looks for
  the `linux-musl` engine instead of `linux-musl-openssl-3.0.x`. The `build`
  **and `prod`** stages of `orders-ms`, `products-ms` and `auth-ms` run
  `apk add --no-cache openssl`; keep both.
- `products-ms` uses SQLite and the image includes `prisma/.dev.db` (the
  `.dockerignore` only excludes `prisma/*.db-journal`), so the seeded DB ships
  inside the image. The prod stage also runs
  `chown -R node:node /usr/src/app/prisma`: without it SQLite fails with
  `attempt to write a readonly database` because the container runs as `node`.
  There is no volume, so writes live in the container layer (ephemeral).

## 12. Kubernetes local (minikube)

- The Helm chart `k8s/tienda` deploys the whole stack: `client-gateway`,
  `products-ms`, `orders-ms`, `auth-ms`, `payments-ms` and `nats-server`.
  Only `client-gateway`, `payments-ms` and `nats-server` have Services; the
  other microservices communicate only over NATS.
- Images are loaded into minikube with
  `minikube image load localhost:5000/<service>:1.0.0`; the chart uses
  `imagePullPolicy: IfNotPresent`. `localhost:5000` inside a pod is the node,
  not the host, so the local registry is **not** directly reachable from pods.
- Databases stay **external** (same as `docker-compose.prod.yml`): the dev
  Postgres (`orders_database`, host 5433) and Mongo (`auth_database`, host
  27017) run in Docker on the host. Pods reach them at
  `host.minikube.internal`; Mongo keeps `directConnection=true`.
- `products-ms` uses the SQLite DB baked into the image; writes are ephemeral
  (no PVC).
- Credentials live in the `tienda-secrets` Secret (not in the chart):
  `AUTH_DATABASE_URL`, `ORDERS_DATABASE_URL`, `JWT_SECRET`, `JWT_EXPIRES_IN`
  and `STRIPE_*`. Create/update it with `kubectl` before
  `helm upgrade --install tienda k8s/tienda`.
- Smoke test: port-forward `svc/client-gateway` 3000 and `svc/payments-ms`
  3003, then `./smoke-test.sh`.
