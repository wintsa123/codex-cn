# Slash commands

For an overview of Codex CLI slash commands, see [this documentation](https://developers.openai.com/codex/cli/slash-commands).

This fork also adds `/loop [interval] <prompt>`, which rewrites the request into a normal user turn that asks the model to call the scheduled-task tools and create a recurring task. If `interval` is omitted, it defaults to `10m`. `/loop` accepts compact leading intervals such as `30s`, `10m`, `2h`, `1d`, and trailing phrases like `review PR every 2 hours`.

To use `/loop`, make sure scheduled tasks are enabled in `config.toml` (this is the default):

```toml
disable_cron = false
```

Examples:

```text
/loop 15m check build status
/loop review PR every 2 hours
```

Set `disable_cron = true` in `config.toml` to disable the scheduled-task tools and hide `/loop` from the command picker.
