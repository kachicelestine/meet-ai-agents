# Meet AI

An AI-native video meeting platform where every session is paired with a configurable AI agent. Agents participate in calls in real time, and when a call ends the platform automatically transcribes, diarizes, and summarizes the conversation using GPT-4o — all without user intervention.

---

## Table of Contents

- [System Overview](#system-overview)
- [Architecture](#architecture)
- [Data Flow](#data-flow)
- [Tech Stack & Rationale](#tech-stack--rationale)
- [Database Schema](#database-schema)
- [API Design](#api-design)
- [Freemium & Billing Model](#freemium--billing-model)
- [Design Decisions & Trade-offs](#design-decisions--trade-offs)
- [Local Development](#local-development)
- [Environment Variables](#environment-variables)
- [Project Structure](#project-structure)

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Browser (React 19)                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │  Dashboard   │  │  Video Call  │  │  Transcript / Chat   │  │
│  │  (tRPC RSC)  │  │ (Stream SDK) │  │  (Stream Chat SDK)   │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘  │
└─────────┼────────────────-┼────────────────────-┼──────────────┘
          │ tRPC/HTTP        │ WebRTC              │ WebSocket
          ▼                  ▼                     ▼
┌─────────────────┐  ┌──────────────────────────────────────────┐
│  Next.js 15     │  │            Stream.io Platform            │
│  App Router     │  │  ┌─────────────┐   ┌──────────────────┐ │
│  ┌───────────┐  │  │  │ Stream Video│   │  Stream Chat     │ │
│  │ tRPC API  │  │  │  │ (WebRTC)    │   │  (WebSocket)     │ │
│  │ Handlers  │  │  │  │             │   │                  │ │
│  └─────┬─────┘  │  │  └──────┬──────┘   └──────────────────┘ │
│        │        │  │         │ Webhook on call end            │
└────────┼────────┘  └─────────┼──────────────────────────────-─┘
         │                     │
         ▼                     ▼
┌────────────────┐    ┌────────────────────────────────────────┐
│  Neon          │    │  Inngest (Background Job Queue)        │
│  PostgreSQL    │    │  ┌──────────────────────────────────┐  │
│  (Serverless)  │    │  │  meetings/processing function    │  │
│                │    │  │  1. fetch transcript (JSONL)     │  │
│  Drizzle ORM   │    │  │  2. diarize speakers             │  │
│                │    │  │  3. GPT-4o summarize             │  │
└────────────────┘    │  │  4. persist summary + status     │  │
                      │  └──────────────────────────────────┘  │
                      └────────────────────────────────────────┘
                                        │
                                        ▼
                             ┌──────────────────┐
                             │  OpenAI GPT-4o   │
                             │  (Summarization) │
                             └──────────────────┘

Auth: Better Auth  ──►  GitHub / Google OAuth + Email/Password
Billing: Polar.sh  ──►  Subscription-gated tRPC middleware
```

---

## Architecture

The codebase follows a **feature-module architecture** with a strict server/client boundary inside each module. Each domain (agents, meetings, auth, call, premium) owns its schema types, tRPC procedures, and UI in isolation.

```
src/modules/<domain>/
├── server/
│   └── procedures.ts     ← tRPC router (server-only, DB access)
├── ui/
│   ├── views/            ← Page-level React components (RSC by default)
│   └── components/       ← Domain-specific client components
├── hooks/                ← URL-synced filter state (nuqs)
├── schemas.ts            ← Zod validation (shared server + client)
├── types.ts              ← Domain types
└── params.ts             ← nuqs param definitions
```

All tRPC procedures are composed at `src/trpc/routers/_app.ts` and served through `src/app/api/trpc/[trpc]/route.ts`.

---

## Data Flow

### Meeting Lifecycle

```
[User creates meeting]
        │
        ▼
tRPC: meetings.create (premiumProcedure)
  ├── INSERT into meetings (status: "upcoming")
  ├── streamVideo.video.call("default", meetingId).create(...)
  │     └── transcription: auto-on, recording: 1080p auto-on
  └── streamVideo.upsertUsers([agent])   ← register AI agent as Stream user
        │
        ▼
[User joins call]  ──► Stream Video WebRTC session
[AI agent joins]   ──► Stream Video (agent_id participates as Stream user)
        │
        ▼
[Call ends] ──► Stream webhook fires
        │
        ▼
Inngest event: "meetings/processing" { meetingId, transcriptUrl }
        │
        ├── step.run("fetch-transcript")   → GET transcriptUrl → raw JSONL text
        ├── step.run("parse-transcript")   → JSONL.parse<StreamTranscriptItem[]>
        ├── step.run("add-speakers")       → JOIN user + agent rows by speaker_id
        └── summarizer.run(transcript)     → GPT-4o structured markdown summary
              │
              ▼
        step.run("save-summary")
          └── UPDATE meetings SET summary=..., status="completed"
```

Each Inngest `step.run` is independently retried on failure — a network blip on the transcript fetch does not re-run the GPT-4o call.

### Auth Flow

```
[Sign in] ──► Better Auth handler (/api/auth/[...all])
  ├── Email/password  →  bcrypt hash check, session cookie issued
  ├── GitHub OAuth    →  OAuth code exchange, account linked to user
  └── Google OAuth    →  OAuth code exchange, account linked to user
        │
        ▼
Better Auth Drizzle adapter writes: user, session, account, verification tables
tRPC protectedProcedure reads session from headers on every request
```

---

## Tech Stack & Rationale

| Layer | Choice | Why |
|---|---|---|
| Framework | Next.js 15 (App Router) | RSC for zero-bundle data fetching; streaming; native API routes |
| Language | TypeScript 5 | End-to-end type safety across tRPC schema → DB → UI |
| API | tRPC v11 + TanStack Query v5 | Type-safe RPC with no codegen; stale-while-revalidate caching for free |
| Database | Neon PostgreSQL (serverless) | Branching for preview envs; scales to zero; HTTP driver for edge compat |
| ORM | Drizzle ORM | SQL-first, zero overhead, schema as source of truth for migrations |
| Auth | Better Auth | First-class Drizzle adapter; OAuth + email/password; pluggable (Polar plugin) |
| Video | Stream Video (LiveKit) | Managed WebRTC infra; built-in auto-transcription + recording |
| Chat | Stream Chat | Real-time WebSocket messaging; SDKs for React |
| Background Jobs | Inngest | Durable step functions; per-step retry; local dev via webhook tunnel |
| AI | OpenAI GPT-4o via `@inngest/agent-kit` | Structured summarization; agent-kit wraps tool-use patterns |
| Billing | Polar.sh | OSS-friendly Stripe alternative; Better Auth plugin for session binding |
| UI | Radix UI + shadcn/ui + Tailwind CSS v4 | Headless accessible primitives; zero-runtime styling |
| State (URL) | nuqs | URL-as-state for filters; shareable, back-button-aware, SSR-compatible |
| Validation | Zod | Runtime schema shared between server procedures and React Hook Form |

---

## Database Schema

```sql
-- Auth tables (managed by Better Auth)
user         (id, name, email, emailVerified, image, createdAt, updatedAt)
session      (id, token, userId → user, expiresAt, ipAddress, userAgent)
account      (id, userId → user, providerId, accessToken, refreshToken, ...)
verification (id, identifier, value, expiresAt)

-- Domain tables
agents  (id [nanoid], name, userId → user, instructions [text], createdAt, updatedAt)

meetings (
  id          [nanoid],
  name        text,
  userId      → user    ON DELETE CASCADE,
  agentId     → agents  ON DELETE CASCADE,
  status      meeting_status ENUM (upcoming|active|completed|processing|cancelled),
  startedAt   timestamp,
  endedAt     timestamp,
  transcriptUrl text,    -- JSONL file URL served by Stream
  recordingUrl  text,
  summary       text,    -- GPT-4o markdown output
  createdAt   timestamp,
  updatedAt   timestamp
)
```

Meeting duration is a computed column derived at query time:

```sql
EXTRACT(EPOCH FROM (ended_at - started_at)) AS duration
```

---

## API Design

All mutations and queries are exposed through tRPC, organized into two routers merged in `_app.ts`.

### Procedure Middleware Chain

```
baseProcedure
  └── protectedProcedure      (validates Better Auth session via headers)
        └── premiumProcedure  (checks Polar active subscription + free-tier limits)
```

`premiumProcedure` accepts an `entity` parameter (`"meetings" | "agents"`) so the same middleware enforces per-entity quotas with a single implementation.

### Key Procedures

| Procedure | Type | Auth | Description |
|---|---|---|---|
| `agents.create` | mutation | premium | Create agent; enforces `MAX_FREE_AGENTS` |
| `agents.update` | mutation | protected | Update name/instructions; scoped to `userId` |
| `agents.remove` | mutation | protected | Hard delete; cascades to meeting FK |
| `agents.getOne` | query | protected | Fetch agent + computed `meetingCount` |
| `agents.getMany` | query | protected | Paginated list with `ilike` search |
| `meetings.create` | mutation | premium | Insert row + create Stream Video call + register agent user |
| `meetings.getOne` | query | protected | Fetch meeting + joined agent + computed duration |
| `meetings.getMany` | query | protected | Paginated + filtered (status, agentId, search) |
| `meetings.getTranscript` | query | protected | Fetch + diarize JSONL transcript from Stream CDN |
| `meetings.generateToken` | mutation | protected | Issue scoped Stream Video JWT (1h TTL) |
| `meetings.generateChatToken` | mutation | protected | Issue Stream Chat JWT + upsert user |

All `getMany` procedures enforce `MIN_PAGE_SIZE` / `MAX_PAGE_SIZE` bounds and return `{ items, total, totalPages }`.

---

## Freemium & Billing Model

```
Free tier:
  MAX_FREE_AGENTS   = N  (defined in src/modules/premium/constants.ts)
  MAX_FREE_MEETINGS = N

Premium tier (Polar.sh subscription):
  Unlimited agents and meetings

Enforcement path:
  premiumProcedure
    → GET /customers/getStateExternal (Polar API, by userId)
    → COUNT agents WHERE userId
    → COUNT meetings WHERE userId
    → if (free limit reached && no active subscription) → FORBIDDEN
```

Polar is configured in sandbox mode during development. The Better Auth Polar plugin automatically creates a Polar customer record on first sign-up, binding it to the user's `id` as `externalId`.

---

## Design Decisions & Trade-offs

### 1. tRPC over REST or GraphQL

**Decision:** tRPC v11 with TanStack Query.

**Why:** End-to-end type safety with zero codegen is the right call for a monorepo where the client and server are co-located. GraphQL's flexibility is overkill for a product with well-defined, caller-specific queries. REST would require maintaining a separate OpenAPI spec.

**Trade-off:** tRPC is not usable from non-TypeScript clients. If a mobile app or external integration is added later, a parallel REST or gRPC surface will be needed.

---

### 2. Drizzle over Prisma

**Decision:** Drizzle ORM with Neon serverless driver.

**Why:** Drizzle is SQL-first — queries compose naturally with `and()`, `ilike()`, `count()`, and computed columns (`sql<number>`). The schema file is the migration source of truth. Prisma's query engine binary is incompatible with edge runtimes and adds cold-start overhead on serverless.

**Trade-off:** Drizzle's relation API is less ergonomic than Prisma's `include`. Joins must be written explicitly (which is actually a feature — no N+1 surprises). Complex polymorphic queries require more boilerplate.

---

### 3. Inngest for Post-Call Processing

**Decision:** Inngest durable step functions instead of a simple webhook handler.

**Why:** The post-call pipeline has three distinct failure domains: transcript fetch (network), speaker diarization (DB), and GPT-4o summarization (external API + latency). Encoding each as an `step.run` block gives per-step retry with exponential backoff at no extra infrastructure cost. A plain API route would retry the entire pipeline on any failure, including re-invoking GPT-4o unnecessarily.

**Trade-off:** Inngest requires an outbound webhook tunnel in local dev (`ngrok`). The event schema between the Stream webhook and Inngest is implicit — a malformed payload silently no-ops rather than failing loudly.

---

### 4. Stream Video for WebRTC

**Decision:** Stream Video (LiveKit-backed) managed WebRTC over self-hosted Jitsi or raw mediasoup.

**Why:** Auto-transcription and recording are first-class features in Stream's call settings (`mode: "auto-on"`). Building this on raw WebRTC would require a media server, TURN infrastructure, a transcription pipeline, and a recording store — weeks of infra work. Stream handles all of it with a single API call at call creation time.

**Trade-off:** Hard dependency on a third-party platform. Transcript format (JSONL via `StreamTranscriptItem`) is Stream-specific, making migration to another provider non-trivial. Egress pricing can become significant at scale.

---

### 5. Better Auth over NextAuth / Clerk

**Decision:** Better Auth with Drizzle adapter.

**Why:** Better Auth owns its schema entirely in the application's DB — no shadow tables, no external user store. The Polar plugin integrates subscription state directly into the session lifecycle (customer created on sign-up). NextAuth v5 has a similar model but weaker plugin system. Clerk externalizes the user store, complicating foreign key relationships with `agents` and `meetings`.

**Trade-off:** Better Auth is newer and has a smaller ecosystem than NextAuth. Some edge cases (e.g., enterprise SSO, MFA) require custom plugin development rather than dropping in a community package.

---

### 6. URL State with nuqs

**Decision:** `nuqs` for filter and search state in list views instead of React `useState`.

**Why:** URL-driven state makes filtered views shareable and bookmarkable, survives page refresh, and integrates with RSC — the server can read filter params and pre-render filtered results. `useState` filters are invisible to the server and require an extra client round-trip.

**Trade-off:** URL state changes trigger a full RSC re-render (navigation). For filters that update on every keystroke, a debounce is required to avoid excessive server requests.

---

### 7. Freemium Enforcement in tRPC Middleware

**Decision:** Quota checks live in `premiumProcedure`, not in UI components.

**Why:** Client-side enforcement is security theater — any user can call tRPC directly. Encoding limits in a server-side middleware guarantees enforcement regardless of how the procedure is invoked. The middleware performs three async calls (Polar API + two DB count queries) on every guarded mutation.

**Trade-off:** Three serial I/O operations on every `create` mutation adds latency (~100–300ms). This can be optimized later with a cached subscription status (e.g., stored on the session or in Redis with a short TTL) at the cost of eventual consistency on plan downgrades.

---

## Local Development

### Prerequisites

- Node.js 20+
- A [Neon](https://neon.tech) database
- A [Stream](https://getstream.io) project (Video + Chat)
- An [OpenAI](https://platform.openai.com) API key
- A [Polar](https://polar.sh) account (sandbox)
- [ngrok](https://ngrok.com) for Inngest webhook tunneling

### Setup

```bash
# 1. Install dependencies
npm install

# 2. Copy and fill environment variables
cp .env.example .env.local

# 3. Push schema to Neon (no migration files — schema-push workflow)
npm run db:push

# 4. Start the dev server
npm run dev

# 5. In a separate terminal, expose the Inngest webhook endpoint
npm run dev:webhook
# (requires NGROK_STATIC_DOMAIN set in your shell)
```

The app is available at `http://localhost:3000`.

To inspect the database visually:

```bash
npm run db:studio
```

---

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `DATABASE_URL` | Yes | Neon PostgreSQL connection string |
| `BETTER_AUTH_SECRET` | Yes | Random secret for session signing (min 32 chars) |
| `BETTER_AUTH_URL` | Yes | Canonical app URL used by Better Auth for redirects |
| `GITHUB_CLIENT_ID` | Yes | GitHub OAuth app client ID |
| `GITHUB_CLIENT_SECRET` | Yes | GitHub OAuth app client secret |
| `GOOGLE_CLIENT_ID` | Yes | Google OAuth client ID |
| `GOOGLE_CLIENT_SECRET` | Yes | Google OAuth client secret |
| `NEXT_PUBLIC_APP_URL` | Yes | Public base URL (same as `BETTER_AUTH_URL` in most envs) |
| `NEXT_PUBLIC_STREAM_VIDEO_API_KEY` | Yes | Stream Video public API key (exposed to browser) |
| `STREAM_VIDEO_SECRET_KEY` | Yes | Stream Video secret for server-side token generation |
| `NEXT_PUBLIC_STREAM_CHAT_API_KEY` | Yes | Stream Chat public API key (exposed to browser) |
| `STREAM_CHAT_SECRET_KEY` | Yes | Stream Chat secret for server-side token generation |
| `OPENAI_API_KEY` | Yes | OpenAI API key for GPT-4o summarization via Inngest |
| `POLAR_ACCESS_TOKEN` | Yes | Polar sandbox access token for subscription management |

> `NEXT_PUBLIC_` variables are bundled into the client. Never put secrets in `NEXT_PUBLIC_` variables.

---

## Project Structure

```
src/
├── app/
│   ├── (auth)/              # Sign-in / sign-up route group (no shared layout)
│   ├── (dashboard)/         # Authenticated app (sidebar + navbar layout)
│   │   ├── agents/
│   │   └── meetings/
│   ├── api/
│   │   ├── auth/[...all]/   # Better Auth catch-all handler
│   │   ├── inngest/         # Inngest webhook endpoint
│   │   └── trpc/[trpc]/     # tRPC HTTP handler
│   └── call/[meetingId]/    # Full-screen call UI (outside dashboard layout)
│
├── components/              # Shared, domain-agnostic UI primitives
│   ├── data-table.tsx       # TanStack Table wrapper
│   ├── data-pagination.tsx
│   ├── responsive-dialog.tsx  # Dialog on desktop, Vaul drawer on mobile
│   └── ui/                  # shadcn/ui generated components
│
├── db/
│   ├── index.ts             # Drizzle + Neon serverless client
│   └── schema.ts            # Single source of truth for all table definitions
│
├── inngest/
│   ├── client.ts            # Inngest client singleton
│   └── functions.ts         # meetingsProcessing background function
│
├── lib/
│   ├── auth.ts              # Better Auth instance (server-only)
│   ├── auth-client.ts       # Better Auth browser client
│   ├── polar.ts             # Polar SDK client
│   ├── stream-video.ts      # Stream Video server client (server-only)
│   └── stream-chat.ts       # Stream Chat server client (server-only)
│
├── modules/                 # Feature-module vertical slices
│   ├── agents/
│   ├── auth/
│   ├── call/
│   ├── dashboard/
│   ├── meetings/
│   └── premium/
│
└── trpc/
    ├── init.ts              # tRPC instance, context, middleware (protectedProcedure, premiumProcedure)
    ├── server.tsx           # RSC caller (for server component data fetching)
    ├── client.tsx           # TanStack Query provider + tRPC client
    ├── query-client.ts      # Shared QueryClient factory
    └── routers/
        └── _app.ts          # Root router merging agents + meetings routers
```
