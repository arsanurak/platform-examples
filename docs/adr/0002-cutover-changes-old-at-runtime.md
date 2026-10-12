# 2. Cutover changes the old cluster at runtime, and old's Argo CD ignores those fields

Date: 2026-10-07

## Status

Superseded by [ADR 3](0003-example-config-not-a-runnable-demo.md).

## Context

A **Cutover** switches a **Wave**'s routing to the **New cluster** and scales the old copies to zero while keeping their definitions. A **Rollback** puts both back. Old's Argo CD syncs every App with `selfHeal: true`, so it would undo a replica count or a route that differs from git within minutes.

Three ways to stop that fight:

- **Change git and let Argo CD sync.** The purest GitOps, but the demo runs on a laptop: `make cutover` would need to commit and push to the repo Argo CD watches, and a Rollback would be a revert. Slow, and it ties a local tour to a remote branch.
- **Pause automated sync for the Wave's Apps.** The ApplicationSet owns those Applications and resets a patched sync policy, so this needs `ignoreApplicationDifferences` as well, and old's Apps then stop self-healing anything at all.
- **Ignore just the two fields cutover touches.** Old's ApplicationSet sets `ignoreDifferences` on Deployment `/spec/replicas` and HTTPRoute `/spec/rules`, with `RespectIgnoreDifferences=true` so a sync doesn't reset them either.

## Decision

Ignore the two fields. `make cutover` changes them with kubectl after printing its plan and only with `CONFIRM=1`, and records the values it replaces in `build/cutover/wave-N.json`. `make rollback` replays that file. Clients keep entering through old's gateway: cutover adds a selector-less `<app>-via-new` Service on old whose EndpointSlice is the new gateway's address, and points the HTTPRoute at it.

## Consequences

- Everything else on old still self-heals from git, including the Deployment's pod template and the HTTPRoute's hostnames.
- Git no longer says how many replicas old runs or where its routes point. The rollback file and `kubectl get` do.
- The rollback file lives on the machine that ran the cutover. Lose it and `make rollback` has nothing to replay; the git definitions (1 replica, backend `<app>`) are the fallback.
- In production, cutover would be a reviewed change to git (or to DNS or a global load balancer in front of both clusters), and rollback a revert.
