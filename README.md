# Orderly

Orderly is the backend for an online shop's ordering system, written in Go. Customers browse products, sign up, place orders and pay. The system tracks stock so nothing is oversold and sends a confirmation when an order goes through.

It is a learning project that grows week by week, from a single Go service into a set of services that talk over gRPC and Kafka, run in Docker on Railway, and deploy to Kubernetes.

> **Status:** work in progress. See [Roadmap](#roadmap) for what is done and what is next.

## Features

- Product catalogue with prices in minor units (cents/paisa)
- Customer sign-up and login (JWT access tokens + refresh tokens)
- Role-based access: customers see their own orders, admins see all
- Order placement that never oversells stock, even under concurrent requests
- Idempotent `POST /orders` using an `Idempotency-Key` header
- Product caching and per-user rate limiting with Redis
- Checkout saga: reserve stock → charge payment → confirm order, with compensation on failure
- Event-driven services using Kafka (with a transactional outbox) and RabbitMQ (notification jobs with a dead-letter queue)
- CQRS read model for fast order listing
- Health checks, structured logs, Prometheus metrics and OpenTelemetry tracing

## Architecture

```mermaid
flowchart LR
    client(["Client"])

    subgraph gateway_layer["Gateway"]
        gw["api-gateway<br>REST, auth, rate limit"]
        redis[("Redis")]
    end

    subgraph services["Services"]
        order["order-service"]
        inv["inventory-service"]
        pay["payment-service"]
        view["order-view<br>CQRS read model"]
    end

    orderdb[("Postgres<br>orders + outbox")]
    invdb[("Postgres<br>stock")]
    viewdb[("Postgres<br>order view")]

    kafka(["Kafka"])
    rabbit(["RabbitMQ"])
    dlq(["Dead-letter queue"])
    notify["notification-worker"]

    client -->|REST + JWT| gw
    gw --- redis
    gw -->|gRPC| order
    gw -->|gRPC| inv
    gw -->|gRPC| view

    order --> orderdb
    inv --> invdb
    view --> viewdb

    orderdb -->|outbox relay| kafka
    kafka -->|order.placed| inv
    inv -->|inventory events| kafka
    kafka -->|inventory.reserved| pay
    pay -->|payment events| kafka
    kafka -->|payment events| order
    kafka -->|all events| view

    pay -->|confirmation job| rabbit
    rabbit --> notify
    rabbit -->|after retries| dlq
```

### Checkout saga

The services coordinate checkout through Kafka events (choreography). If payment fails, inventory releases the stock and the order is cancelled.

```mermaid
sequenceDiagram
    participant O as order-service
    participant K as Kafka
    participant I as inventory-service
    participant P as payment-service
    O->>K: order.placed
    K->>I: order.placed
    I->>K: inventory.reserved
    K->>P: inventory.reserved
    alt payment succeeds
        P->>K: payment.succeeded
        K->>O: payment.succeeded
        Note over O: order confirmed
    else payment fails
        P->>K: payment.failed
        K->>I: payment.failed
        Note over I: stock released
        K->>O: payment.failed
        Note over O: order cancelled
    end
```

| Service | Responsibility | Talks via |
|---|---|---|
| `api-gateway` | Public REST API, auth, rate limiting, caching | REST in, gRPC out |
| `order-service` | Orders, checkout rules, outbox | gRPC, Kafka |
| `inventory-service` | Stock levels, reservations | gRPC, Kafka |
| `payment-service` | Charges via a mock payment provider | Kafka, RabbitMQ |
| `order-view` | Read-optimised order list (CQRS projection) | Kafka |
| `notification-worker` | Sends confirmations (stubbed) | RabbitMQ |

## Tech stack

| Area | Choice |
|---|---|
| Language | Go 1.23+ |
| HTTP | `net/http` + [chi](https://go-chi.io/), `log/slog` |
| Database | PostgreSQL 16, [pgx](https://github.com/jackc/pgx), [sqlc](https://docs.sqlc.dev/), [goose](https://github.com/pressly/goose) migrations |
| Cache | Redis 7, [go-redis](https://github.com/redis/go-redis) |
| RPC | gRPC + Protocol Buffers, [buf](https://buf.build/) |
| Messaging | Kafka ([franz-go](https://github.com/twmb/franz-go)), RabbitMQ ([amqp091-go](https://github.com/rabbitmq/amqp091-go)) |
| Testing | Go `testing`, [testcontainers-go](https://golang.testcontainers.org/), k6 for load tests |
| Deploy | Docker, Docker Compose, Railway, Kubernetes (kind locally), Helm |
| CI | GitHub Actions |
| Observability | Prometheus metrics, OpenTelemetry tracing |

## Project layout

```
orderly/
├── cmd/
│   ├── api-gateway/        # main packages, one per service
│   ├── order-service/
│   ├── inventory-service/
│   ├── payment-service/
│   ├── order-view/
│   └── notification-worker/
├── internal/
│   ├── order/              # domain: entities, rules, service (no HTTP/SQL imports)
│   ├── inventory/
│   ├── payment/
│   ├── auth/               # JWT, password hashing, RBAC middleware
│   ├── platform/           # db, redis, kafka, rabbitmq, logging, config
│   └── httpx/              # middleware, error responses
├── proto/                  # .proto files (buf)
├── migrations/             # SQL migrations (goose)
├── queries/                # SQL for sqlc
├── deploy/
│   ├── docker-compose.yml
│   ├── k8s/                # manifests / Helm values
│   └── railway/
├── docs/
│   ├── notes/              # weekly theory notes
│   └── design.md           # architecture and trade-offs
├── loadtest/               # k6 scripts
├── Makefile
└── README.md
```

## Getting started

### Prerequisites

- Go 1.23+
- Docker and Docker Compose
- `make`
- Optional: `psql`, `redis-cli`, `grpcurl`, `kind`, `kubectl`, `k6`

### Run locally

```bash
git clone https://github.com/mbilaljawwad/orderly.git
cd orderly
cp .env.example .env
make up          # starts Postgres, Redis, Kafka, RabbitMQ with Docker Compose
make migrate     # applies database migrations
make run         # runs the API on http://localhost:8080
```

Check it is alive:

```bash
curl http://localhost:8080/healthz
```

### Configuration

Configuration comes from environment variables (12-factor style).

| Variable | Example | Purpose |
|---|---|---|
| `HTTP_ADDR` | `:8080` | API listen address |
| `DATABASE_URL` | `postgres://orderly:orderly@localhost:5432/orderly?sslmode=disable` | Postgres connection |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis connection |
| `KAFKA_BROKERS` | `localhost:9092` | Kafka bootstrap servers |
| `RABBITMQ_URL` | `amqp://guest:guest@localhost:5672/` | RabbitMQ connection |
| `JWT_SECRET` | *(set your own)* | Signs access tokens |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

Never commit real secrets. `.env` is in `.gitignore`.

### Make targets

| Command | What it does |
|---|---|
| `make run` | Run the API locally |
| `make test` | Unit tests |
| `make test-integration` | Integration tests with testcontainers |
| `make race` | Tests with the race detector |
| `make lint` | golangci-lint |
| `make up` / `make down` | Start / stop local dependencies |
| `make migrate` | Apply migrations |
| `make sqlc` | Regenerate database code |
| `make proto` | Regenerate gRPC code with buf |
| `make docker` | Build the Docker image |
| `make loadtest` | Run k6 load tests |

## API

Base URL: `/v1`. Errors follow [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem details.

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/auth/register` | none | Create a customer account |
| `POST` | `/auth/login` | none | Get access and refresh tokens |
| `POST` | `/auth/refresh` | refresh token | Get a new access token |
| `POST` | `/auth/logout` | customer | Revoke the refresh token |
| `GET` | `/v1/products` | none | List products (cursor pagination) |
| `GET` | `/v1/products/{id}` | none | Get one product (cached) |
| `POST` | `/v1/products` | admin | Create a product |
| `PATCH` | `/v1/products/{id}` | admin | Update a product |
| `POST` | `/v1/orders` | customer | Place an order (`Idempotency-Key` header required) |
| `GET` | `/v1/orders` | customer | List my orders |
| `GET` | `/v1/orders/{id}` | customer | Get one of my orders |
| `GET` | `/v1/admin/orders` | admin | List all orders |
| `GET` | `/healthz` | none | Liveness |
| `GET` | `/readyz` | none | Readiness (DB, Redis reachable) |
| `GET` | `/metrics` | none | Prometheus metrics |

Example:

```bash
curl -X POST http://localhost:8080/v1/orders \
  -H "Authorization: Bearer $TOKEN" \
  -H "Idempotency-Key: 6f1c2a1e-0b7a-4c55-9b0e-3f1e2d4c5a6b" \
  -H "Content-Type: application/json" \
  -d '{"lines":[{"product_id":"p_123","quantity":2}]}'
```

## Testing

```bash
make test               # fast unit tests, no external services
make test-integration   # real Postgres/Redis via testcontainers
make race               # go test -race ./...
```

Key tests that must always pass:

- 50 concurrent orders for an item with 10 in stock: exactly 10 succeed
- Replaying an order with the same `Idempotency-Key` returns the first result
- No token → 401, wrong role → 403, another customer's order → 404
- A failed payment releases reserved stock and cancels the order

## Deployment

- **Railway:** the API deploys from `main` with Railway's Postgres and Redis add-ons. Migrations run on deploy. See `deploy/railway/`.
- **Kubernetes:** `deploy/k8s/` has manifests for a local [kind](https://kind.sigs.k8s.io/) cluster, with liveness and readiness probes, resource limits and rolling updates.
- **CI:** GitHub Actions runs lint, tests and the Docker build on every push.

## Roadmap

- [x] **Week 0** · Repo, Makefile, tooling
- [ ] **Week 1** · Domain model and table-driven tests (in-memory repository)
- [ ] **Week 2** · REST API, middleware, graceful shutdown, worker pool with channels
- [ ] **Week 3** · PostgreSQL, migrations, sqlc, safe concurrent stock updates
- [ ] **Week 4** · Redis cache, rate limiting, idempotency keys, authentication and authorization
- [ ] **Week 5** · Docker, Compose, GitHub Actions, Railway deploy, metrics
- [ ] **Week 6** · Split inventory service, gRPC with deadlines and auth interceptor
- [ ] **Week 7** · Transactional outbox → Kafka, RabbitMQ notifications with DLQ
- [ ] **Week 8** · Checkout saga, CQRS read model, circuit breaker
- [ ] **Week 9** · Kubernetes with kind, probes, rolling updates
- [ ] **Week 10** · k6 load test, OpenTelemetry tracing, design write-up

Tick these off as you finish each week's checkpoint.

## Design decisions

The trade-offs behind each choice (sqlc over an ORM, choreography vs orchestration for the saga, Railway vs Kubernetes, and so on) are written up in [`docs/design.md`](docs/design.md).

## License

MIT
