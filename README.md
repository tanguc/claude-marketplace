# tanguc marketplace

A Claude Code plugin marketplace by [Sergen Tanguc](https://sergentanguc.com).

## Install

```shell
# in Claude Code:
/plugin marketplace add stanguc/tanguc-marketplace
/plugin install <plugin-name>@tanguc
```

## Plugins

| Plugin | Description |
|--------|-------------|
| [`op-bulk-cache`](./plugins/op-bulk-cache) | Fetch a whole 1Password vault in one biometric prompt, then read secrets instantly from a `/tmp` cache. Kills `op` biometric spam inside Claude Code sessions. |

## Contributing

Issues and PRs welcome. Each plugin lives in its own directory under `plugins/` and is independently versioned via its `plugin.json`.

## License

[MIT](./LICENSE)
