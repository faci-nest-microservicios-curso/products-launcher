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
- Known drift: `orders-ms/prisma/schema.prisma` `enum OrderStatus` lacks `PAID`
  while the Postgres enum already has it, so `GET /api/orders` fails with
  `Value 'PAID' not found in enum 'OrderStatus'`. Add `PAID` to the schema (and
  regenerate) to fix.

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
