# GitHub Webhook Ack And Failure Visibility Plan

## Scope
- Extend `codex github` so users get immediate visible feedback when a webhook command is accepted.
- Keep current async execution model.
- Preserve existing success and failure reply behavior.

## Intended changes
- Add an explicit acknowledgment path before background execution starts.
- For comment-triggered events, prefer an `eyes` reaction on the triggering comment when possible.
- For non-comment triggers, post a short issue/PR/review acknowledgment message.
- Expand failure notification to cover pre-queue failures when a reply target exists.
- Add targeted unit tests for ack and failure-notification paths.
- Update webhook docs to describe the new behavior.

## Files
- `codex-rs/cli/src/github_cmd.rs`
- `codex-rs/docs/github-webhook.md`
- `docs/config.md` if behavior contract needs mention

## Risks
- Need to preserve existing response routing semantics for issue comments, review comments, and pull-request reviews.
- Reaction APIs differ between issue comments and pull request review comments.
- Pre-queue failures cannot notify for `push` because there is no response target.

## Validation
- `cd codex-rs && cargo test -p codex-cli github_cmd`
- `cd codex-rs && just fmt`
- broader regression / CI checks after focused tests pass
