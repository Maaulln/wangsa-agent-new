# Wangsa Mobile

<!-- impeccable:product-schema 1 -->

## Platform

android

## Users

People who describe a need and want an agent to carry out the work, explain its
result, and retain a reusable procedure. Android is the first release; iOS and
web come later. A narrower initial customer segment remains undecided.

## Product Purpose

Turn a user's request into a persistent agent job and a reviewable result.
Successful procedures can become private, versioned skills for future jobs.

## Operating Context

The Android client must survive backgrounding and intermittent connectivity.
Jobs run on the backend and remain visible after reconnecting or signing in
again. Users supply their own model provider API key.

## Capabilities and Constraints

- Account authentication and provider setup precede paid agent work.
- Tenant identity comes from server authentication, never a submitted profile path.
- Jobs, credentials, runtime files, and skills belong to one tenant.
- Clarification and cancellation are first-class job states.
- Skills start as drafts and are reviewed before activation.
- Preserve the existing Flutter app and its legacy gateway/voice integration.
- Production hosting, account recovery, push delivery, and distribution remain
  deployment work; their availability must never be implied by a local demo.

## Product Principles

- Explain what happened and what the user can do next.
- Preserve work across lost connections.
- Ask for credentials only where they are used; never put secrets in a skill.
- Keep profile and runtime implementation details out of the main task flow.
