# Media Vault — Architecture


> Version 1.2 — living document. Update it whenever a decision changes (see ADRs in `docs/adr/`).
> The build order lives on the [Media Vault project board](https://github.com/users/hrvanovicm/projects/8); §13 mirrors it.
>
> v1.2 (2026-10-22): board populated (8 epics, 68 tasks), plugin acceptance contract made explicit,
> estimates reconciled to 118 senior days.


---


## 1. What is Media Vault?


Media Vault is a **self-hosted / on-premise media & file storage platform** with built-in
processing intelligence. Instead of every business app re-implementing "where do I store this,
how do I resize it, is it safe, what is in it", apps delegate that to Media Vault.


Core promise:


> Give us a file and a set of rules. We store it, transform it, scan it, understand it,
> and give you back the file **and its data**.


Design goals, in priority order:


1. **Pluggable everywhere** — storage providers, auth, runners, AI adapters and queue backends
   are all interchangeable plugins, not hardcoded choices.
2. **Pluggable storage** — S3 first, more providers later (local disk, Google Drive, Azure Blob…).
3. **Pluggable processing** — "Runners" (antivirus, AI detection, parsers) are **separate
   processes** that can live on **different machines**.
4. **Per-file-system rules** — every file system has a JSON configuration (formats, quality,
   resolutions, defaults) editable via UI or any tool that can edit JSON.
5. **Files are not just bytes** — files carry *features* (GPS polygons, AI labels, EXIF…)
   queryable through the API.
6. **Cheap to run** — low RAM, low heap pressure, streams instead of buffers, scales
   horizontally. One small VM should comfortably serve a small business.
7. **Multi-tenant & enterprise-friendly** — accounts → applications → file systems, API keys,
   audit trail, quotas.


### Pluggability by design


Every extension point follows **one pattern**: a small Go interface + a registry
(`map[string]Factory` populated via `init()`) + a config switch. Swapping Keycloak for the
built-in auth, adding a Google Drive provider, or writing a new runner must never touch core
code — you add a package and point a config value at it.


| Extension point | Interface | Built-in implementations |
|---|---|---|
| **Auth** | `auth.Authenticator` | `local` (Argon2id + JWT/sessions), `oidc` (Keycloak, go-oidc), `custom` (example/template) |
| **Storage** | `storage.Provider` | `s3` (v1); `local`, `gdrive`, `azure` planned; `custom` (example/template) |
| **Runners** | runner `Work(ctx, job)` via `runners/framework` | `antivirus`, `transform`, `ai-detect`, `gpx-parse`; `custom` via registry |
| **AI adapters** | `aidetect.Provider` | OpenAI Vision, Google Vision, self-hosted endpoint; `custom` template |
| **Queue** | `jobs.Queue` (Enqueue/Claim/Ack/Nack) | `pgqueue` (v1); NATS JetStream / RabbitMQ / custom |


### The plugin contract (definition of done)


A backend is not "pluggable" until **all six** are true:


1. A small interface lives in a core package and contains no vendor types.
2. A registry (`map[string]Factory`) is populated by `init()`.
3. One config key selects the implementation; an unknown ID fails startup and lists the
   registered IDs.
4. A shared contract test suite runs against every implementation in CI.
5. A compiling reference implementation lives under `examples/` and is built in CI.
6. `depguard` (or `go list`) fails the build if a core package imports a concrete adapter.


Auth is the clearest example: `local` and `oidc` (Keycloak) ship as first-class adapters, and
`examples/auth-static` proves a third, custom adapter needs one package plus one config value.
The same rule applies to storage providers, runners, AI adapters and queue backends.


### How a plugin is wired (same pattern everywhere)


1. Implement the interface in its own package, e.g. `internal/storage/gdrive`.
2. Register a factory from `init()` — no core file changes:
   ```go
   func init() {
       storage.Register("gdrive", func() storage.Provider { return &Provider{} })
   }
   ```
3. Select it in `vaultd.yaml` / `vault-runner.yaml`:
   ```yaml
   auth:
     provider: local        # local | oidc | <custom>
   storage:
     provider: s3           # s3 | local | gdrive | azure | <custom>
   queue:
     driver: postgres       # postgres | nats
   ai:
     provider: openai       # openai | google | selfhosted | <custom>
   runners:
     enabled: [antivirus, transform]
   ```
4. Core packages import **only** the interface and registry, never a concrete adapter. An
   unknown ID fails startup with the list of registered IDs.
5. Every plugin ships the shared contract tests (`storage.Provider`, `jobs.Queue`,
   `runners.Handler`, `auth.Authenticator`, `aidetect.Provider`) so a new backend is trusted
   by construction.
6. CI enforces the boundary with `depguard`/`go list`: a core package that imports an adapter
   fails the build.


This is the rule behind every item on the board marked as a provider, adapter or runner.
Auth is deliberately two first-class plugins from day one — built-in local accounts **or**
Keycloak/OIDC — and both are selected by config, not by a fork. A custom adapter follows the
same route and is covered by `examples/auth-static`.


---


## 2. Domain model (the vocabulary)


| Term | Meaning | Example |
|---|---|---|
| **Account** | A human user who administers the platform. | `alice@example.com` |
| **Application** | A tenant/namespace inside Media Vault (like a Keycloak realm / client). Owns API keys and file systems. | `twitter` |
| **File System** | A named logical store inside an Application, bound to a **provider** and a **JSON config**. | `avatars` → S3 bucket `prod-avatars` |
| **Provider / Driver** | The physical storage backend behind a file system. | `s3` (v1), `local`, `gdrive` (later) |
| **File** | One stored object + its metadata + its variants + its features. | `avatars/u/42/photo.jpg` |
| **Variant** | A derived representation of a file (resized/compressed/re-encoded). | `photo.webp @ 320px` |
| **Feature** | Structured data extracted from a file, stored in DB and queryable. | GPX polygon, AI labels, EXIF GPS |
| **Runner** | A separate worker process that consumes jobs of one kind. | `antivirus`, `ai-detect`, `gpx-parser` |
| **Job** | A unit of work on the queue with a **priority**, consumed by runners. | "scan file X" |
| **Preset / Rule** | The JSON config attached to a file system that decides what happens to a file on ingest. | "make 3 image variants, 80% quality" |


```
Account
 └── Application (tenant)
      ├── API keys (scoped credentials for enterprise apps)
      └── File System "avatars"
           ├── provider: s3://prod-avatars
           ├── config: { image variants, runner rules, defaults }
           └── Files
                ├── variants
                ├── features (GPS, AI, …)
                └── processing state (scanning → ready | infected | failed)
```


> Naming note: the tenant entity is called **Application** per the current decision.
> In code we may prefer `tenant` / `project` / `space` to avoid confusing "the Application"
> with "the software". Decide once, rename everywhere (ADR-001).


---


## 3. Tech stack & rationale


| Concern | Choice | Why |
|---|---|---|
| Language | **Go 1.22+** | Single static binary, goroutines, **very low RAM/heap**, first-class S3 & HTTP, easy to ship runners to any machine. |
| Database | **PostgreSQL 16** (+ PostGIS for geo features) | Relational source of truth for tenants, files, features; JSONB for configs; PostGIS gives real spatial queries over GPX data. |
| Queue | **Postgres-backed queue (`SKIP LOCKED`)** behind a `Queue` interface | Zero extra infrastructure for v1, priorities via ordering, horizontal runner scaling for free. Interface allows swapping in NATS JetStream / RabbitMQ later **without touching runners**. |
| Object storage | **Any S3-compatible** (AWS S3, MinIO, Cloudflare R2, Backblaze B2) | The "provider" for v1. MinIO for fully self-hosted deployments. Any other backend is a plugin. |
| Image processing | **libvips via `bimg`** | Processes images at **5–10× lower memory** than ImageMagick, streaming-friendly, fast. Never run ImageMagick for this workload. |
| Antivirus (runner) | **ClamAV (`clamd`)** over TCP/Unix socket | Battle-tested, self-hostable, daemonized — the runner just feeds it streams. |
| AI detection (runner) | Pluggable adapters: OpenAI Vision / Google Vision / self-hosted model endpoint | Interface + registry, same pattern as storage providers and runners. |
| Auth (humans) | **Pluggable `Authenticator` interface** with two first-class adapters: `local` (Argon2id + short-lived JWT / opaque sessions) and `oidc` (Keycloak via go-oidc) — plus a custom-adapter template | Keycloak and self-hosted accounts both ship with v1; adding another IdP is one new adapter package, zero core changes. |
| Auth (apps) | **API keys per Application**, SHA-256 hashed at rest, scoped, rate-limited | Enterprise apps call Media Vault with keys, never with user sessions. |
| Cache | **None required for v1** (optional Redis later) | Deliberate: Redis is a RAM cost. Postgres handles the queue; presigned URLs need no server-side state. |


### Why this is a "low RAM" architecture


- All file I/O is **streamed** (`io.Copy`), never buffered whole in memory.
- Uploads: **presigned PUT directly to S3** — Media Vault never proxies bytes (bandwidth **and** RAM).
- Image transforms use libvips (no full-decode-into-RAM).
- Runners are **separate processes** — a memory-hungry AI SDK cannot destabilize the API.
- Stateless API servers → cheap horizontal scaling behind a load balancer.
- Go GC + bounded worker pools (`sync.Pool` for buffers) keep heap flat.


---


## 4. System overview


```
                          ┌────────────────────────────────────────────┐
  Enterprise app ──API──▶ │              MEDIA VAULT                   │
  (keys, REST)            │                                            │
                          │  ┌──────────────┐   ┌──────────────────┐   │
  Admin user ──UI/REST──▶ │  │  Control     │   │  Data API        │   │
                          │  │  Plane API   │   │  (ingest/query/  │   │
                          │  │  accounts,   │   │   download)      │   │
                          │  │  apps, FS,   │   └────────┬─────────┘   │
                          │  │  configs     │            │             │
                          │  └──────┬───────┘            │ presigned   │
                          │         │                    │ URLs        │
                          │  ┌──────▼───────────────────▼───────┐     │
                          │  │           PostgreSQL             │     │
                          │  │  tenants · files · features ·    │     │
                          │  │  jobs (queue) · events · PostGIS │     │
                          │  └──────┬───────────────────────────┘     │
                          └─────────┼─────────────────────────────────┘
                                    │ SKIP LOCKED polls (per job kind)
      ┌─────────────────────────────┼──────────────────────────────┐
      │            RUNNERS (separate processes, any machine)       │
      │                                                             │
      │  ┌──────────┐   ┌──────────────┐   ┌────────────────────┐   │
      │  │ antivirus│   │  ai-detect   │   │  parser (gpx/…)    │   │
      │  │  (clamd) │   │  (vision API)│   │  (pure Go, cheap)  │   │
      │  └──────────┘   └──────────────┘   └────────────────────┘   │
      └─────────────────────────────┬───────────────────────────────┘
                                    │ write results (features, status)
                    ┌───────────────▼─────────────────┐
                    │   Object storage (S3-compatible)│
                    │   originals + variants, one     │
                    │   bucket (or prefix) per FS     │
                    └─────────────────────────────────┘
```


**Lifecycle of a file:**


1. Client asks Data API: *"I want to PUT `avatars/u/42/photo.jpg`"* → API creates the file row
   (`status=pending`), returns a **presigned PUT URL**.
2. Client uploads **directly to S3**; client calls `complete` (or the API is notified via webhook/queue).
3. Ingest pipeline (inside the API process, cheap steps only):
   - verify size/ETag/hash → dedupe check (same SHA-256 = same file, reuse);
   - run **synchronous transforms** for small/medium images (libvips is fast — user gets variants immediately);
   - enqueue **jobs**: `antivirus` (priority 1), `ai-detect` (2), `gpx-parse` (3) per the file system config.
4. Runners pick jobs up by priority, stream the object from S3, and write results back:
   - antivirus: `clean` → file becomes `ready`; `infected` → file quarantined, **not downloadable**;
   - ai-detect: labels/NSFW/exif → stored as features;
   - parser: GPX → points/polygon → PostGIS geometry.
5. Enterprise app polls `GET /files/{key}` or receives a **webhook** (`file.ready`), then fetches
   the file, its variants, or its features.


> Files stay `pending` (not downloadable) until the antivirus job completes. Security before convenience.


---


## 5. File system JSON configuration


Every file system carries a JSON document — stored in Postgres (`filesystems.config JSONB`),
editable via UI **or** via API **or** by any tool that can produce valid JSON (file manager,
scripts, GitOps). Schema-versioned, validated on save, never applied partially.


```json
{
  "schema_version": 1,
  "images": {
    "variants": [
      { "name": "thumb",  "format": "webp", "quality": 80, "width": 320,  "height": 320, "fit": "cover" },
      { "name": "medium", "format": "webp", "quality": 85, "width": 1024 },
      { "name": "large",  "format": "webp", "quality": 90, "width": 2048 }
    ],
    "default_variant": "medium",
    "keep_original": true,
    "strip_metadata": true
  },
  "defaults": {
    "store_original": true,
    "allowed_content_types": ["image/*", "application/pdf", "application/gpx+xml"],
    "max_size_bytes": 52428800
  },
  "runners": {
    "antivirus": { "enabled": true, "priority": 1 },
    "ai_detect":  { "enabled": true, "priority": 2, "labels": ["nsfw", "objects"], "min_confidence": 0.7 },
    "gpx_parse":  { "enabled": true, "priority": 3, "store_geometry": true }
  },
  "features": {
    "gps":  { "index": true },
    "exif": { "extract": ["camera", "gps"] }
  },
  "dedupe": true,
  "retention_days": null
}
```


Rules of the config system:


- **Config is declarative.** The platform computes the diff and applies it (e.g. regenerating
  variants when quality changes). No half-applied states.
- **Unknown keys → validation error**, never silently ignored.
- **Per-file-type sections** (images, video, documents, default catch-all) so a file system can
  hold mixed content with different rules.
- Config changes are **audited** (`config_audit` table: who, when, diff).
- Plugin selection (auth, storage, queue, AI) is **deployment config**, not file-system config;
  a file system may only choose which enabled runners run for its files.


---


## 6. Storage provider abstraction


Providers are plugins behind one interface — S3 today, more tomorrow.


```go
// internal/storage/storage.go (interface contract)
type Provider interface {
    ID() string                                  // "s3", "local", "gdrive"


    // Lifecycle
    Init(ctx context.Context, cfg ProviderConfig) error
    Ping(ctx context.Context) error


    // Object ops (all streaming!)
    Put(ctx context.Context, key string, r io.Reader, opts PutOptions) (*PutResult, error)
    Get(ctx context.Context, key string) (io.ReadCloser, *ObjectInfo, error)
    Delete(ctx context.Context, key string) error
    Head(ctx context.Context, key string) (*ObjectInfo, error)
    List(ctx context.Context, prefix string, cursor string, limit int) ([]ObjectInfo, string, error)


    // Direct-upload support
    PresignPut(ctx context.Context, key string, ttl time.Duration, size int64) (url string, err error)
    PresignGet(ctx context.Context, key string, ttl time.Duration) (url string, err error)


    // Optional capabilities, so the API knows what to fall back to
    Capabilities() Capabilities   // { Multipart: true, Presign: true, Events: false, ... }
}
```


- `ProviderConfig` contains the connection details (endpoint, bucket, credentials) — **encrypted
  at rest** in DB, never logged, never returned by the API.
- Registry pattern (`map[string]func() Provider` + `init()`), identical to how runners and AI
  adapters are registered. Adding Google Drive = one new package, zero changes to core.
- Every provider passes the same contract suite: streaming Put/Get, range reads, missing keys,
  presign TTL, capability fallbacks, path-safe keys. `examples/storage-local` is the reference
  custom provider and is compiled in CI.
- Bucket layout per file system: one bucket per FS (recommended) or prefix-scoped buckets.
  Variants live under `v/<variant>/<key>`; originals under `o/<key>`.
- Core imports only `storage`; `depguard` blocks a direct import of the S3 SDK outside
  `internal/storage/s3`.


---


## 7. Runners & the job queue


### 7.1 Runner principles


- One binary, many runners: `media-vault-runner antivirus`, `media-vault-runner ai-detect`, …
  Same binary, different subcommand → trivial to deploy one kind per machine.
- Runners are **dumb and stateless**: they poll `jobs` for their kind, stream from S3, do work,
  write results. Any number of identical runners = horizontal scaling.
- A runner crash must **never** lose work: lease + heartbeat + ack model.
- Runner code is shared (`internal/runners/framework`) so a new runner is ~100 lines.
- Every runner implements `runners.Handler` and passes the shared contract suite.
  `examples/runner-noop` is the template for a custom runner; adding one requires a package and
  a registry call, never a core edit.


### 7.2 Queue design (v1: Postgres `SKIP LOCKED`)


```sql
CREATE TABLE jobs (
    id            BIGSERIAL PRIMARY KEY,
    kind          TEXT        NOT NULL,            -- antivirus | ai_detect | gpx_parse | transform
    priority      SMALLINT    NOT NULL DEFAULT 100,-- lower = sooner
    file_id       BIGINT      NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    payload       JSONB       NOT NULL,
    attempts      SMALLINT    NOT NULL DEFAULT 0,
    max_attempts  SMALLINT    NOT NULL DEFAULT 5,
    available_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_by     TEXT,                             -- runner id
    locked_at     TIMESTAMPTZ,
    finished_at   TIMESTAMPTZ,
    error         TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX jobs_claim_idx ON jobs (kind, priority, available_at)
    WHERE finished_at IS NULL;
```


Claim: `SELECT … FOR UPDATE SKIP LOCKED ORDER BY priority, id LIMIT batch`.
Priorities are numbers, so "antivirus before AI before parser" is just an ordering
(`1, 2, 3`), and custom priorities are expressible per file system config.


**Why not a broker for v1?** One less daemon to run, one less failure domain, transactions
with the file row for free. The `Queue` interface (`Enqueue/Claim/Ack/Nack`) is the only thing
runners see → swapping in NATS JetStream or RabbitMQ later changes nothing else. Every queue
backend runs the same contract suite (claim ordering, lease recovery, ack/nack, dedupe window).


### 7.3 Safety mechanisms (non-negotiable)


- **Lease timeouts**: runner heartbeats; if it dies, the job becomes claimable again
  (`locked_at < now() - lease`).
- **Poison messages**: after `max_attempts` → `dead` state + alert; never infinite retry loops.
- **Exponential backoff**: attempts 1–5 wait 30s, 2m, 10m, 30m, 1h.
- **Idempotency**: runners write results with `ON CONFLICT DO UPDATE`; running twice is safe.
- **Priority aging**: jobs waiting > X minutes get a priority bump so low-priority work never
  starves forever.
- **Ordering guarantee**: the file only becomes `ready` when **all enabled required jobs**
  finished successfully — enforced by a small state machine on `files.status`, not by the queue.


### 7.4 File status state machine


```
 pending ──▶ scanning ──▶ ready
               │  │
               │  └──▶ infected (quarantined, never downloadable)
               └──▶ failed (retryable manually, reason stored)
```


---


## 8. Features (the "not just files" part)


A **feature** is typed structured data attached to a file. Stored as JSONB + first-class
typed columns where it matters (geometry → PostGIS):


```sql
CREATE TABLE file_features (
    id      BIGSERIAL PRIMARY KEY,
    file_id BIGINT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    type    TEXT    NOT NULL,          -- 'gps', 'ai_labels', 'exif', 'pdf_meta', ...
    data    JSONB   NOT NULL,
    geom    GEOMETRY(Geometry, 4326),  -- for gps tracks/polygons (PostGIS)
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (file_id, type)
);
```


Examples:


- **GPX**: parser writes `data` (distance, duration, elevation profile summary) **and** `geom`
  (track polygon). Then you can query *"all rides within 5 km of this point"* with a real
  spatial index — the API returns the file **and** its geo data.
- **AI detect**: labels, confidence, NSFW flag, OCR text excerpt.
- **EXIF**: camera, GPS point, orientation.
- **PDF**: page count, extracted text location (for later full-text search).


API: `GET /v1/files/{key}/features` returns all of it; `GET /v1/files?near=lat,lng&radius=5000`
returns files filtered by feature data.


---


## 9. API surface


Two planes, one HTTP server.


### 9.1 Control plane (account auth — sessions/JWT)


```
POST   /v1/auth/register · /login · /logout
POST   /v1/applications                          create tenant
GET    /v1/applications/{app}
POST   /v1/applications/{app}/keys               create API key (scoped)
POST   /v1/applications/{app}/filesystems        create FS (name, provider, creds)
GET    /v1/applications/{app}/filesystems/{fs}/config
PUT    /v1/applications/{app}/filesystems/{fs}/config   ← THE JSON config endpoint
GET    /v1/audit?application={app}               audit trail
```


### 9.2 Data plane (API-key auth — what enterprise apps call)


```
POST   /v1/files/{fs}                            create file record → presigned PUT URL (+idempotency key)
PUT    /v1/files/{fs}/{key}/complete             confirm upload, kick off pipeline
GET    /v1/files/{fs}/{key}                      metadata + status + variants
GET    /v1/files/{fs}/{key}/download             presigned GET redirect (or proxied stream)
GET    /v1/files/{fs}/{key}/variants/{variant}   presigned GET for a specific variant
GET    /v1/files/{fs}/{key}/features             all extracted features
GET    /v1/files/{fs}?near=lat,lng&radius=5000   feature-based search
DELETE /v1/files/{fs}/{key}
POST   /v1/webhooks                              register webhook (file.ready, file.infected, …)
```


Conventions:


- Auth: `Authorization: Bearer <api-key>`; the key encodes its Application scope → **tenants
  can never see each other's files**.
- Idempotent uploads via `Idempotency-Key` header; dedupe by content SHA-256 across the FS.
- Responses never expose provider credentials or presigned URLs longer than needed.
- Rate limits per key; usage counters (bytes, files) per Application → quota support later.


---


## 10. Data model (core tables)


```
accounts        id · email · password_hash · status · created_at
applications    id · account_id · name · slug · status · quotas · created_at
app_members     application_id · account_id · role
api_keys        id · application_id · key_hash · prefix · scopes · expires_at · last_used_at
filesystems     id · application_id · name · slug · provider · provider_config(enc)
                · config JSONB · status · created_at
files           id · filesystem_id · key · size · content_type · sha256 · status
                · variant_default · created_at · updated_at
                UNIQUE (filesystem_id, sha256)  ← dedupe
file_variants   id · file_id · name · format · width · height · quality · size
                · sha256 · storage_key
file_features   id · file_id · type · data JSONB · geom (PostGIS)
jobs            (see §7.2)
events          id · application_id · type · payload JSONB · created_at
config_audit    id · filesystem_id · account_id · diff JSONB · created_at
```


---


## 11. Repository / folder structure


Go workspace, `internal/` keeps the core unimportable from outside; `cmd/` is the only
entry-point surface. `examples/` holds compiling plugins that prove the boundary.


```
media-vault/
├── ARCHITECTURE.md               ← this file
├── Makefile                      build · test · lint · migrate
├── go.mod · go.work
│
├── cmd/
│   ├── vaultd/                   # THE server: control plane + data API + ingest pipeline
│   │   └── main.go
│   ├── vaultctl/                 # admin CLI (bootstrap account, migrate, health, inspect queue)
│   └── vault-runner/             # ONE runner binary, subcommands per kind
│       └── main.go               #   vault-runner antivirus|ai-detect|gpx-parse
│
├── internal/
│   ├── server/                   # wiring, lifecycle, graceful shutdown, HTTP server
│   ├── config/                   # YAML config loading, env overrides, validation
│   │
│   ├── api/                      # HTTP layer
│   │   ├── controlplane/         #   accounts, applications, filesystems, config, audit
│   │   ├── dataplane/            #   files, variants, features, presign, webhooks
│   │   └── middleware/           #   auth, api-keys, ratelimit, request-id, recover
│   ├── auth/                     # ★ auth abstraction
│   │   ├── auth.go               #   Authenticator interface, Principal, registry
│   │   ├── local/                #   Argon2id + JWT/session adapter
│   │   └── oidc/                 #   Keycloak / generic OIDC adapter
│   │
│   ├── tenancy/                  # applications, memberships, quotas
│   ├── filesystem/               # filesystem entity + JSON config schema, validate, diff
│   │
│   ├── storage/                  # ★ provider abstraction
│   │   ├── storage.go            #   Provider interface, Capabilities, registry
│   │   └── s3/                   #   v1 provider (minio-go / aws-sdk-go-v2)
│   │
│   ├── files/                    # file records, status state machine, dedupe
│   ├── transform/                # variant presets, libvips pipeline (bimg), async overflow
│   ├── features/                 # feature storage + query (PostGIS helpers)
│   │   └── gpx/                  #   GPX parsing → track, polygon, stats
│   │
│   ├── jobs/                     # ★ queue abstraction
│   │   ├── queue.go              #   Enqueue/Claim/Ack/Nack interface + registry
│   │   └── pgqueue/              #   Postgres SKIP LOCKED implementation
│   │
│   ├── runners/                  # ★ runner framework + built-in runners
│   │   ├── framework/            #   claim loop, lease, heartbeat, backoff, metrics
│   │   ├── antivirus/            #   clamd adapter
│   │   ├── aidetect/             #   AI adapters (openai vision, google vision, self-hosted)
│   │   └── parser/               #   gpx, exif, pdf
│   │
│   ├── events/                   # event log + webhook delivery (retry, signature HMAC)
│   ├── ingest/                   # the upload→job pipeline orchestration
│   └── store/                    # DB access: repos, transactions
│
├── examples/                     # proof that plugins need no core edits (built in CI)
│   ├── auth-static/              #   custom Authenticator
│   ├── storage-local/            #   custom storage.Provider
│   ├── runner-noop/              #   custom runners.Handler
│   └── aidetect-static/          #   custom AI adapter
│
├── pkg/                          # safe-to-share libs (hashing, limits, errgroup helpers)
├── migrations/                   # numbered SQL migrations (goose/golang-migrate)
├── configs/                      # example vaultd.yaml, docker-compose (postgres+minio+clamd)
├── deployments/                  # Dockerfiles, k8s manifests (api vs runner deployments)
└── docs/
    ├── adr/                      # architecture decision records (ADR-001 …)
    └── api/                      # OpenAPI spec
```


Deployment shape (docker-compose / k8s):


- `vaultd` — 1..N replicas behind LB (stateless).
- `vault-runner antivirus` — N replicas, colocated with a `clamd` sidecar.
- `vault-runner ai-detect` — M replicas (scale with AI latency/cost).
- `vault-runner gpx-parse` — cheap, few replicas.
- `postgres` (+PostGIS), `minio` — single instance to start, HA later.


---


## 12. Things to keep an eye on (pitfalls & invariants)


**Memory / performance**


- Never `io.ReadAll` an upload or download. Stream everything; presign where possible.
- Cap multipart upload concurrency; cap request body size **before** reading.
- libvips, not ImageMagick. Timeout every transform; oversized images go to the async path.
- Bound every worker pool; reuse buffers via `sync.Pool`; keep the API process stateless so a
  bad request can't balloon a long-lived process.
- Watch DB connection pool (pgbouncer when replicas grow) — never 1 goroutine = 1 conn.


**Queue & runners**


- Lease expiry must be longer than the slowest legitimate job (a 100 MB AV scan takes minutes).
- Runners must be **idempotent**; assume every job runs at least once.
- Poison messages need a dead-letter view + alerting, not silent drops.
- Low-priority jobs must age (priority bump) or they will starve under load.
- File must not become `ready` until **all** enabled required jobs passed (§7.4).


**Storage & providers**


- Provider credentials: encrypted at rest, masked in logs, never in API responses.
- Presigned URLs: short TTL, scoped to one key, HTTPS-only; don't leak them into logs.
- Keys are user-controlled strings → **path traversal & object-name collisions** must be
  sanitized (`..`, absolute paths, control chars). Variant names are reserved.
- Variants are immutable: name = config version + content hash → cache-friendly forever.
- Config changes (e.g. new quality) → regenerate variants as jobs, then flip the default atomically.


**Tenancy & security**


- Every query filters by `application_id` — enforced in the repo layer, tested in CI.
- API keys are scoped to exactly one Application; keys are hash-only after creation.
- Infected/pending files are **never** downloadable; AV always runs before any feature runs.
- AI output is **untrusted data** (prompt injection via image/OCR text exists): store it as
  data, never execute it, never reflect it unescaped.
- Audit everything: config changes, key creation, downloads, deletions.


**Operations**


- Graceful shutdown: stop accepting, drain, finish in-flight jobs.
- Metrics from day one: queue depth & lag per kind, p95 ingest latency, runner throughput,
  RAM/heap of every process. These tell you when to scale which runner.
- Health endpoints: liveness (process) vs readiness (DB + storage ping).
- Backups: Postgres is the source of truth (files are recoverable **only** with their rows);
  back it up before the buckets.


---


## 13. Project board and build order


**Board:** <https://github.com/users/hrvanovicm/projects/8> (project **Media Vault**)


The board is the source of truth for work. It contains **76 items: 8 epics + 68 tasks**. Every
item has an **Estimate** in senior days (tasks only; epics roll up in their body), a **Size**
(XS–XL), a **Priority** (P0 foundation, P1 Release 1, P2 later), a **Kind**, a numeric key
(`E1.1`, `E1.2`, …) and an **Order** number (1–76). Tasks are sub-issues of their epic. Sort by
**Order** ascending to get the exact build sequence; the manual card order matches it.

- **Ready — Release 1 (43 items: epics E1–E4 + 39 tasks).** Work the next numbered Task.
- **Backlog — Releases 2+ (33 items: epics E5–E8 + 29 tasks).** Closed for work until E4.9 passes.

Epics are markers and parents, not work items. The board order is the build order; do not
reorder cards. Each task assumes the previous one is done.


### Rules for working the board


1. **Ready = Release 1 only.** Work the lowest-numbered Ready task; do not start a second one.
2. Flow: `Ready → In progress → In review → Done`. Branch per task (`e1-1-repo-skeleton`), one
   PR, squash merge, then move the card.
3. **Backlog is closed for work** until E4.9 passes. It contains releases 2+; pulling a task
   forward needs a written reason (new customer requirement, blocked dependency).
4. Epics are parents, not work items. An epic is done when all its sub-issues are done.
5. Estimates are **senior developer days** (focused work, not calendar). If a task is off by
   more than 50%, update the estimate and leave a one-line note.
6. A task is done only when its "Done when" list is satisfied and CI is green.
7. **Plugin tasks carry the plugin contract** from §1: interface, registry, config switch,
   shared contract suite, compiling example, and a `depguard` boundary. Missing any one of
   them means the task is not done.
8. **One task at a time.** Finish it, merge one PR, move the card, then start the next. This
   board is ordered for a single developer, not for parallel streams.


### Release 1 — Ready (E1–E4)


| Key | Issue | Task | Days | Size |
|---|---|---|---|---|
| **E1** | #2 | Foundation: repo, config, auth, API keys *(Epic)* | 12.5 | XL |
| **E1.1** | #3 | Repo skeleton and build tooling | 0.5 | XS |
| **E1.2** | #4 | CI pipeline for lint, tests and build | 0.5 | XS |
| **E1.3** | #5 | Config loader with env overrides | 1 | S |
| **E1.4** | #6 | Database pool, migrations and base schema | 1 | S |
| **E1.5** | #7 | HTTP server, router and middleware | 1 | S |
| **E1.6** | #8 | Health and readiness endpoints | 0.5 | XS |
| **E1.7** | #9 | Auth plugin interface and registry | 1 | S |
| **E1.8** | #10 | Local auth adapter and first admin | 2 | M |
| **E1.9** | #11 | Keycloak and OIDC auth adapter | 2 | M |
| **E1.10** | #12 | API keys: issue, hash, scopes and middleware | 2 | M |
| **E1.11** | #13 | Dev environment and setup guide | 1 | S |
| **E2** | #14 | Tenancy and storage: applications, file systems, S3 *(Epic)* | 17.5 | XL |
| **E2.1** | #15 | Applications, members and roles | 2 | M |
| **E2.2** | #16 | Tenant isolation in repositories | 1.5 | M |
| **E2.3** | #17 | Storage provider interface and registry | 1 | S |
| **E2.4** | #18 | S3 provider with presigned transfers | 2.5 | L |
| **E2.5** | #19 | File systems and encrypted provider config | 2 | M |
| **E2.6** | #20 | File system API and lifecycle | 1.5 | M |
| **E2.7** | #21 | Upload intent and presigned PUT | 2 | M |
| **E2.8** | #22 | Complete upload, verify and dedupe | 2 | M |
| **E2.9** | #23 | Download, variant URLs and key safety | 1.5 | M |
| **E2.10** | #24 | File listing, filters and delete | 1.5 | M |
| **E3** | #25 | Transforms: JSON config and image variants *(Epic)* | 15 | XL |
| **E3.1** | #26 | File system config schema v1 | 2 | M |
| **E3.2** | #27 | Config API and change audit | 1 | S |
| **E3.3** | #28 | Variant planner and deterministic keys | 1.5 | M |
| **E3.4** | #29 | Image transform pipeline with libvips | 3 | L |
| **E3.5** | #30 | Persist variants and pick the default | 1.5 | M |
| **E3.6** | #31 | Synchronous transforms for small images | 1.5 | M |
| **E3.7** | #32 | Variant download API and cache headers | 1 | S |
| **E3.8** | #33 | Config changes and variant regeneration | 2 | M |
| **E3.9** | #34 | Transform fixtures and memory checks | 1.5 | M |
| **E4** | #35 | Jobs and runners: queue, antivirus, gating *(Epic)* | 16.5 | XL |
| **E4.1** | #36 | Queue interface and Postgres implementation | 2.5 | L |
| **E4.2** | #37 | Retries, backoff, dead letter and aging | 1.5 | M |
| **E4.3** | #38 | Runner framework | 2.5 | L |
| **E4.4** | #39 | vault-runner binary and runner registry | 1 | S |
| **E4.5** | #40 | File status state machine and gating | 2 | M |
| **E4.6** | #41 | Antivirus runner with clamd | 2 | M |
| **E4.7** | #42 | Transform runner for large files | 1.5 | M |
| **E4.8** | #43 | Queue and pipeline observability | 1.5 | M |
| **E4.9** | #44 | Release 1 end-to-end smoke test | 2 | M |


**Release 1 total: 39 tasks, ~61.5 senior days.**


**Release 1 means:** a client can create an application and file system, upload directly to
S3, have the file scanned and transformed, then download the original or a variant — with
tenant isolation, pluggable auth (local, Keycloak, or custom), and a queue that survives
runner crashes.


### Later — Backlog (E5–E8)


| Key | Issue | Task | Days | Size |
|---|---|---|---|---|
| **E5** | #45 | AI detection and features *(Epic)* | 9 | XL |
| **E5.1** | #46 | Feature store and API | 2 | M |
| **E5.2** | #47 | AI adapter interface and registry | 1 | S |
| **E5.3** | #48 | OpenAI Vision adapter | 1.5 | M |
| **E5.4** | #49 | Self-hosted or Google Vision adapter | 1.5 | M |
| **E5.5** | #50 | AI detection runner | 1.5 | M |
| **E5.6** | #51 | Feature filtering and AI safety rules | 1.5 | M |
| **E6** | #52 | Geo and document parsers *(Epic)* | 10 | XL |
| **E6.1** | #53 | EXIF extraction runner | 1.5 | M |
| **E6.2** | #54 | GPX parser and track stats | 2 | M |
| **E6.3** | #55 | PostGIS setup and geometry storage | 1.5 | M |
| **E6.4** | #56 | Spatial search API | 2 | M |
| **E6.5** | #57 | PDF metadata and text extraction | 2 | M |
| **E6.6** | #58 | Parser runner packaging and tests | 1 | S |
| **E7** | #59 | Enterprise polish: events, audit, quotas, UI *(Epic)* | 16.5 | XL |
| **E7.1** | #60 | Event log and transactional outbox | 1.5 | M |
| **E7.2** | #61 | Signed webhooks with retries | 2 | M |
| **E7.3** | #62 | Audit log for sensitive actions | 1.5 | M |
| **E7.4** | #63 | Rate limits and application quotas | 2 | M |
| **E7.5** | #64 | vaultctl operator CLI | 2 | M |
| **E7.6** | #65 | OpenAPI spec and generated client | 2 | M |
| **E7.7** | #66 | Admin web UI for config and files | 4 | XL |
| **E7.8** | #67 | Backup, restore and operations runbook | 1.5 | M |
| **E8** | #68 | Providers, media types and scale *(Epic)* | 21 | XL |
| **E8.1** | #69 | Local disk storage provider | 1.5 | M |
| **E8.2** | #70 | Google Drive storage provider | 3 | L |
| **E8.3** | #71 | Azure Blob storage provider | 2.5 | L |
| **E8.4** | #72 | Video transcoding runner with ffmpeg | 3 | L |
| **E8.5** | #73 | Retention and lifecycle sweeper | 1.5 | M |
| **E8.6** | #74 | Storage migration tool | 3 | L |
| **E8.7** | #75 | Full-text search for PDFs and OCR | 2.5 | L |
| **E8.8** | #76 | NATS JetStream queue adapter | 2 | M |
| **E8.9** | #77 | HA deployment and CDN caching | 2 | M |


**Backlog total: 29 tasks, ~56.5 senior days. Whole board: 68 tasks, ~118 senior days.**


Nice-to-haves beyond the board: file versioning, per-Application billing meters, an S3
inventory/consistency checker, and a policy engine for rules more complex than JSON config.


---


## 14. Decisions (closed)


These were open in v1.0; the first implementation now assumes the answers below. Changing one
is an ADR, not a refactor by accident.


| # | Question | Decision |
|---|---|---|
| 1 | **Entity naming** | **Application** everywhere: table `applications`, Go type `Application`, API path `/applications`. No `tenant`/`project` aliases in code. |
| 2 | **Upload style** | **Presigned PUT is the default.** Proxied upload exists only as a fallback for providers without presign (e.g. Google Drive, E8.2). |
| 3 | **AI provider for v1** | Adapter interface first, **OpenAI Vision** as the reference hosted adapter, **self-hosted** as the second adapter. Both are backlog (E5). |
| 4 | **Queue backend** | **Postgres `SKIP LOCKED` for v1.** NATS JetStream is an optional adapter behind the same interface (E8.8), never a hard dependency. |
| 5 | **Auth default** | **`local` is the default** for self-hosted installs; **`oidc`/Keycloak** is a first-class adapter selected by config. Custom auth is a new plugin package (`examples/auth-static`). |
| 6 | **Quotas** | Deferred past Release 1. Usage counters are written from the start; enforcement ships with E7.4. |
| 7 | **Plugin boundary** | A plugin is done only with all six from §1: interface, registry, config switch, contract suite, compiling example, `depguard` rule. This applies to auth, storage, runners, AI adapters and queue backends. |


Still genuinely open: video codec ladder details (E8.4), the exact OCR provider for E8.7, and
whether the admin UI (E7.7) should remain server-rendered or become a SPA. Decide when those
tasks start.
