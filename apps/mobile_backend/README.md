# Wangsa Mobile backend

Android-first product API for accounts, per-user model credentials, durable
agent jobs, and private reusable procedures. This service is separate from the
legacy `wangsa_mobile` gateway adapter on port 9901. It does not multiplex
untrusted user agents inside the gateway process.

## Run locally

From the repository root, with the project's Python dependencies installed and
Docker Engine/Desktop running:

```sh
docker build -f Dockerfile.mobile-runtime -t wangsa-mobile-runtime:local .
.venv/bin/python -m apps.mobile_backend init runtime/mobile-product
.venv/bin/python -m apps.mobile_backend doctor --config runtime/mobile-product/mobile.yaml
.venv/bin/python -m apps.mobile_backend serve --config runtime/mobile-product/mobile.yaml
```

On macOS, if Docker Desktop is running but `docker` is missing or a stale
symlink points to an old installation, use its bundled CLI for this shell:

```sh
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
```

`init` creates an owner-readable master encryption key and YAML configuration.
It refuses to overwrite an existing deployment. Back up `mobile.key` separately
from `data/mobile.sqlite3`: losing the key makes stored provider credentials
unrecoverable. A wrong key causes startup to fail. An operator may instead
provide the secret through `WANGSA_MOBILE_ENCRYPTION_KEY`; behavioral settings
remain in YAML. Never commit keys or deployment state.

The control plane runs on the Docker host as a dedicated service account with
access to the daemon. Agent containers never receive the daemon socket or the
control-plane database. Do not expose Docker's API to users or mount its socket
inside a tenant container.

API health: `http://127.0.0.1:9902/health`. This is a liveness check; the separate
`doctor` command checks daemon and image availability. If Docker is missing,
accounts and provider configuration still work, but agent jobs fail explicitly.
There is deliberately no host-execution fallback.

For a physical Android device:

```sh
adb reverse tcp:9902 tcp:9902
cd apps/mobile
flutter run --dart-define=WANGSA_API_BASE_URL=http://localhost:9902
```

For an Android emulator, use `http://10.0.2.2:9902` or the same ADB reverse.
The mobile client accepts HTTP only for loopback/emulator addresses in debug
builds. Release builds require an explicit HTTPS API origin:

```sh
flutter build appbundle --release --dart-define=WANGSA_API_BASE_URL=https://YOUR-API-HOST
```

Android release signing and the real HTTPS host must be configured for the
deployment. The legacy chat/voice client remains available with
`--dart-define=WANGSA_LEGACY_GATEWAY=true` and its existing port 9901.

## First task

1. Create an account with a username and password. Provider setup is optional
   after sign-in; choose a supported provider and enter its model ID in
   Account → Provider AI. Add your own API key when that provider requires one.
   OpenCode Free is keyless and uses Wangsa's OpenCode Zen runtime routing. Its
   free model catalog can change independently; choose a currently supported
   model. No shared/default credential fallback.
2. Create a job describing the input, expected output, and constraints. For a
   website task, put the site NetID and password in the separate credential
   fields, never in the prompt. Credentials are encrypted in the control-plane
   database, sent to the isolated worker over stdin, and available only through
   `browser_fill_secret`; they are erased when the job reaches a terminal state.
3. Close and reopen the app: the job and its events come from server storage.
4. If the agent asks a question, reply from the job detail. A clarification
   resumes the same job and its original system prompt, toolset, and history.
5. Read the result. A repeatable solution may produce a draft procedure. Review
   the full procedure, activate it, then use it with new input in a new job.

Mobile jobs include an isolated Chromium browser and browser controls. Website
credentials are not part of model messages or tool arguments. Browser results
are scrubbed for those exact credential values before entering conversation
history. Secret entry uses the browser CLI batch stdin channel rather than a
process argument or environment variable. The agent must treat page text as
untrusted and must not save or submit
external records unless the user explicitly asked it to do so. CAPTCHA/MFA may
require a new task; a resumed task starts a fresh browser session and signs in
again using the encrypted job credentials.

Results currently consist of Markdown reports in the app. Files created by the
agent persist in its private workspace; a user-facing file download/upload API
is not part of this version. Do not promise file delivery from a report link.

## Isolation and lifecycle

- SQLite queries enforce authenticated tenant ownership. The client cannot
  supply a profile path or choose another tenant. Passwords use salted scrypt;
  bearer tokens are random, stored hashed, expire, and can be revoked.
- API keys and queued credential snapshots use Fernet encryption. Changing
  provider settings affects new jobs; an existing job keeps its selected model.
  Disconnecting the provider cancels pending jobs and removes credential
  snapshots. Completed/failed/cancelled jobs discard the snapshot.
- A job runs in a non-root container with a read-only root filesystem, dropped
  capabilities, no-new-privileges, resource/time limits, and one tenant's named
  volume. Each execution has its own bridge network; no ports are published.
  Credentials enter via stdin, never Docker arguments or environment settings.
- One supervisor owns a deployment directory. Different tenants can run
  concurrently; jobs within one tenant serialize until the runtime exits,
  including cancellation cleanup, because they share that tenant's workspace.
- Queued jobs survive restarts. A running job interrupted by server failure
  becomes failed and is not silently replayed: external effects may already
  have occurred. Cancellation does not undo completed external effects.
- `Idempotency-Key` is required for creation and clarification. Repeated keys
  with identical input return the same job; different input returns 409.
- Agent-created skills remain drafts in the control plane. Activation checks
  document structure and credential-shaped content; this is not a proof of
  semantic correctness. The Android UI requires explicit review. An active
  procedure is introduced as user input at the start of a new job.

Resource controls use Docker's [run options](https://docs.docker.com/engine/containers/run/).
Containers share the host kernel; deployment hardening follows
[Docker's security model](https://docs.docker.com/engine/security/). Host/network
policy must deny runtime access to cloud metadata, internal infrastructure, and
other private services while permitting the intended provider/tool traffic.
Containers alone do not establish an application-specific outbound allowlist.

## API contract

All product routes start with `/api/mobile/v1`. Successful responses are
`{"data": ...}`; errors are `{"error":{"code":"...","message":"..."}}`.
Authenticated routes require `Authorization: Bearer <token>`.

| Route | Purpose |
| --- | --- |
| `POST /auth/signup`, `POST /auth/login` | `{username,password}` → `{token,user}` |
| `GET /auth/me`, `POST /auth/logout` | Restore/revoke the current session |
| `GET/PUT/DELETE /provider` | Read safe metadata, save provider config, disconnect |
| `GET /provider/catalog` | List supported providers and whether an API key is required |
| `POST /provider/models` | Discover model IDs; transient API key is never saved |
| `GET/POST /jobs` | List/create persistent jobs; creation accepts optional `browser_secrets` (`netid`, `password`) separately from the prompt |
| `GET /jobs/{id}` | Status, result, question, ordered events |
| `POST /jobs/{id}/reply` | Resume with `{message}` and idempotency key |
| `POST /jobs/{id}/cancel` | Request cancellation |
| `GET /skills` | List private drafts and active procedures |
| `POST /skills/{id}/activate` | Activate a reviewed procedure |

Statuses: `queued`, `running`, `needs_input`, `completed`, `failed`, `cancelled`.
Lists currently return the latest 100 entries. This single-host implementation
is intended for a controlled pilot; a distributed worker queue and paginated
history are needed before horizontal scaling.

## Validation and release boundaries

```sh
scripts/run_tests.sh tests/mobile_backend -q
cd apps/mobile
flutter analyze
flutter test
flutter build apk --debug
```

Tests exercise real SQLite transactions, HTTP authorization, concurrency,
idempotency, restart handling, and real AIAgent/SessionDB calls against a local
deterministic model endpoint. Subprocess protocol tests do not substitute for
a live Docker isolation test or live paid-provider acceptance.

`tests/mobile_backend/test_docker_acceptance.py` also runs when Docker and the
locally built runtime image are available (otherwise it skips). It uses real
containers, API requests, the scheduler, AIAgent, and the terminal tool to check
two isolated tenant volumes, read-only paths, non-root execution, persistence,
clarification, procedure review/reuse, and timeout cleanup. Only the model is a
deterministic fixture inside the test container. The fixture never ships in
the production image and does not enable custom provider URLs in the API.

Before public release, complete a real two-account Docker/device acceptance
run, configure HTTPS, signing, encrypted backups and host egress policy, and
provide account recovery/deletion and abuse controls appropriate to the
deployment. Push notifications and monetary spend tracking are not implemented;
the current limits bound jobs, iterations, runtime resources, and elapsed time,
not provider invoices. Existing legacy voice assets have separate licensing
requirements; audit them before distributing a commercial APK.
