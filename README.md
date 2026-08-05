# FCG.Infra

Repositório de **orquestração** da plataforma FCG (Tech Challenge — Fase 3). Centraliza infraestrutura compartilhada e o guia para subir o ambiente com **Docker Compose** ou **Kubernetes**.

## Stack da Fase 3

| Capacidade | Escolha |
|---|---|
| API Gateway | **Kong** (DB-less) — ponto de entrada único + validação JWT no catálogo |
| Observabilidade | **Prometheus + Grafana + Loki + Tempo** (métricas, logs e traces via OTLP) |
| NoSQL | **MongoDB** — avaliações de jogos no Catalog |
| Cache | **Redis** — listagens de jogos |
| Serverless | **Azure Functions** — projeto em [`FCG.Notifications/src/FCG.Notifications.Function`](../FCG.Notifications/src/FCG.Notifications.Function) |
| Relacional | PostgreSQL |
| Mensageria | RabbitMQ |

## Microsserviços

| Repositório | Finalidade |
|---|---|
| [FCG.Users](../FCG.Users) | Cadastro e autenticação JWT |
| [FCG.Catalog](../FCG.Catalog) | Catálogo, biblioteca, compras, avaliações (Mongo) + cache Redis |
| [FCG.Payments](../FCG.Payments) | Processamento assíncrono de pagamentos |
| [FCG.Notifications](../FCG.Notifications) | Notificações serverless (Azure Functions); contém também o worker legado da Fase 2 |

## Arquitetura

```mermaid
flowchart LR
  Client[Client] --> Kong[Kong Gateway]
  Kong -->|/users| Users[Users API]
  Kong -->|/catalog + JWT| Catalog[Catalog API]
  Users --> PG[(PostgreSQL)]
  Catalog --> PG
  Catalog --> Mongo[(MongoDB)]
  Catalog --> Redis[(Redis)]
  Users -->|events| RMQ[(RabbitMQ)]
  Catalog -->|events| RMQ
  RMQ --> Payments[Payments Worker]
  RMQ --> CatalogW[Catalog Worker]
  RMQ -->|trigger| AzFunc[Notifications Function]
  Users --> Prom[Prometheus]
  Catalog --> Prom
  Users --> Otel[OTel Collector]
  Catalog --> Otel
  Otel --> Tempo[Tempo]
  Otel --> Loki[Loki]
  Prom --> Grafana[Grafana]
  Tempo --> Grafana
  Loki --> Grafana
```

## Pré-requisitos

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Compose v2+)
- Para Kubernetes: Minikube/Kind ou cluster com `kubectl`
- Para Notifications local: [Azure Functions Core Tools](https://learn.microsoft.com/azure/azure-functions/functions-run-local) v4

---

## Executar com Docker Compose

```bash
cd FCG.Infra
docker compose up -d
```

### Portas expostas

| Serviço | URL |
|---|---|
| **Kong (entrada da API)** | http://localhost:8000 |
| Kong Admin | http://localhost:8001 |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000 (`admin`/`admin`) |
| Loki | http://localhost:3100 |
| Tempo | http://localhost:3200 |
| OTel Collector (OTLP) | `localhost:4317` (gRPC) / `localhost:4318` (HTTP) |
| RabbitMQ Management | http://localhost:15672 (`admin`/`admin`) |
| PostgreSQL | `localhost:5435` |
| MongoDB | `localhost:27017` |
| Redis | `localhost:6379` |

> Users e Catalog **não** publicam portas no host — o acesso externo é só via Kong.

### Rotas do Gateway

| Método | URL via Kong | Destino |
|---|---|---|
| POST | `http://localhost:8000/users/api/Auth/login` | Users (público) |
| POST | `http://localhost:8000/users/api/Usuario` | Users (público) |
| * | `http://localhost:8000/catalog/api/...` | Catalog (**JWT obrigatório** no Kong) |
| GET | `http://localhost:8000/users/health` | Users health |
| GET | `http://localhost:8000/catalog/health` | Catalog health |

Header nas rotas protegidas: `Authorization: Bearer <token>`

### Credenciais

| Serviço | Usuário | Senha |
|---|---|---|
| PostgreSQL | `postgres` | `postgres` |
| RabbitMQ | `admin` | `admin` |
| Grafana | `admin` | `admin` |
| Admin seed (Users) | `admin@admin.com` | `Teste@123` |

### Notifications (serverless)

O worker de notifications **não** sobe no Compose. Execute a Function localmente (ou no Azure) apontando para o RabbitMQ:

```bash
cd ../FCG.Notifications/src/FCG.Notifications.Function
cp local.settings.json.example local.settings.json
# RabbitMQ: amqp://admin:admin@localhost:5672/
func start
```

---

## Deploy no Kubernetes

Ordem sugerida:

```bash
# Infra base
kubectl apply -f postgres/k8s/
kubectl apply -f rabbitmq/k8s/
kubectl apply -f mongo/k8s/
kubectl apply -f redis/k8s/

# Observabilidade + Gateway
kubectl apply -f prometheus/k8s/
kubectl apply -f grafana/k8s/
kubectl apply -f kong/k8s/

# Apps
kubectl apply -f ../FCG.Payments/k8s/
kubectl apply -f ../FCG.Catalog/k8s/
kubectl apply -f ../FCG.Users/k8s/
```

### NodePorts

| Serviço | NodePort |
|---|---|
| Kong proxy | `30080` |
| Kong admin | `30081` |
| Prometheus | `30090` |
| Grafana | `30300` |
| RabbitMQ Management | `31672` |
| PostgreSQL | `30432` |
| MongoDB | `30017` |

APIs Users/Catalog são **ClusterIP** (acesso via Kong).

---

## Observabilidade

- **Métricas**: Users e Catalog expõem `/metrics` (prometheus-net) → Prometheus → Grafana
- **Traces**: OpenTelemetry (ASP.NET Core + HttpClient) → OTel Collector → Tempo
- **Logs**: OpenTelemetry Logging → OTel Collector → Loki
- Grafana já provisiona datasources **Prometheus**, **Loki** e **Tempo**, com correlação Trace ↔ Log
- Dashboard: **FCG APIs - Observability** (latência p95, request rate, erros 5xx)

No Grafana:
1. **Explore → Loki** — `{service_name="fcg-users-api"}` ou `{service_name="fcg-catalog-api"}`
2. **Explore → Tempo** — Search por service name após gerar tráfego no Postman
3. No Tempo, use **Logs for this span** para ir ao Loki

## Estrutura do repositório

```
FCG.Infra/
├── docker-compose.yml
├── kong/                 # API Gateway DB-less
├── prometheus/
├── grafana/
├── loki/
├── tempo/
├── otel-collector/
├── mongo/
├── redis/
├── postgres/
└── rabbitmq/             # + definitions das filas (incl. notifications)
```

## Checklist do vídeo (Fase 3)

1. Requisições via Kong (login público + catálogo com JWT)
2. Azure Function acionada por mensagem + logs
3. Dashboard Grafana com métricas + Explore Loki/Tempo
4. Avaliações no MongoDB (`POST/GET /catalog/api/Avaliacao`)
5. Cache Redis nas listagens de jogos
