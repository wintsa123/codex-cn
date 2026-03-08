# GitHub Outcome-First Overlay (Experimental)

## Status

This document is an experimental repo-local overlay for future GitHub-driven orchestration.
It is **not** a claim that the current `codex github` runtime already implements this flow.

Today the native webhook path still does the following:

- validates the webhook
- prepares or resumes a worktree
- runs Codex in that worktree
- persists thread state
- writes a direct GitHub reply when the event has a response target

Use this document only when the current session explicitly instructs the agent to use the overlay
and literally names `docs/github-outcome-first-overlay.md`, or when a higher-level orchestrator
explicitly activates the overlay with an equivalent instruction.

## Intent

The target workflow is:

`GitHub Event -> route decision -> requirements clarification or durable execution -> proof -> GitHub writeback`

The routing roles are:

- **requirements compiler**: turn ambiguous intent into a verifier-ready specification
- **durable execution kernel**: execute and recover task state safely
- **proof layer**: decide whether the result is actually done

This repository currently maps those roles conceptually to `prd-compiler`, `harness`, and a future
GitHub-aware orchestrator, but those are overlay roles, not guaranteed built-ins.

## Native Runtime vs Overlay

### Native `codex github` runtime

The current product path is still direct execution:

- webhook ingress
- event parsing and filtering
- worktree preparation
- Codex execution
- thread persistence
- direct GitHub writeback when applicable

### Experimental overlay

Only when explicitly activated by the rule above:

1. If the request is ambiguous, clarify requirements first.
2. Persist a verifier-ready PRD before durable execution.
3. Use a durable execution kernel when recoverable task state is needed.
4. Require proof before declaring the work complete.

If the overlay is not explicitly active, preserve native `codex github` behavior.

## Event Surface

If the runtime enables the corresponding events, the overlay is prepared to reason about:

- `issue_comment` (`created`, `edited`)
- `issues` (`opened`, `edited`, `reopened`)
- `pull_request` (`opened`, `edited`, `reopened`, `synchronize`)
- `pull_request_review` (`submitted`, `edited`)
- `pull_request_review_comment` (`created`, `edited`)
- `push`

This is a compatibility note only. Actual ingress remains controlled by `codex github` configuration,
command-prefix matching, sender permission checks, repo allowlists, HMAC validation, source checks,
and delivery de-duplication.

## Proposed Routing Rules

When the overlay is explicitly active:

1. If the work item is ambiguous or lacks verifier-ready acceptance criteria, stop for clarification or run
   a requirements compiler if one is available.
2. Before durable execution, persist the verifier-ready PRD in a stable artifact.
3. If a durable execution kernel is available and recoverable state is needed, use it instead of ad-hoc task tracking.
4. Keep execution outcomes separate from GitHub writeback buckets.
5. Do not declare completion until proof exists.

If required overlay tooling is missing, do not invent the workflow. Either:

- fall back to native `codex github` behavior when the user did not request the overlay, or
- stop and report the missing capability when the user explicitly requested the overlay.

## Proposed Artifact Contract

These artifacts are **only** expected for overlay-managed runs, not for all native `codex github` runs.
They are rooted at the active worktree directory prepared for the current GitHub work item, and the
overlay-managed session is responsible for creating, updating, and interpreting them during that one
work item lifecycle. They are not durable product guarantees across unrelated future work items.

- `prd/prd.md`
- `proof/summary.md`
- `proof/validation.md`
- `harness-runtime.json`

## Proposed Writeback Buckets

When an overlay-managed event has a GitHub response target, the desired writeback buckets are:

- `clarification_needed`
- `executing`
- `blocked`
- `handoff_with_proof`
- `completed`

For `push`, the current native behavior is still local execution without direct GitHub writeback.

## Future Integration Point

If this overlay ever moves from documentation into product behavior, the right cut is still:

- keep `codex github` as ingress, filtering, and webhook validation
- add a small routing seam after event normalization and before direct execution
- let a higher-level orchestrator choose between requirements clarification, durable execution, and proof collection

Until then, this file is design guidance, not runtime truth.
