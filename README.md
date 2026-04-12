# tanguc marketplace

A Claude Code plugin marketplace by [Sergen Tanguc](https://sergentanguc.com).

## Install

```shell
# in Claude Code:
/plugin marketplace add tanguc/claude-marketplace
/plugin install <plugin-name>@tanguc
```

## Plugins

| Plugin | Description |
|--------|-------------|
| [`op-toolkit`](./plugins/op-toolkit) | Full 1Password CLI toolkit: bulk-cache vaults (one biometric prompt per session), read secrets via `op://` references, and create new items from YAML templates. Kills `op` biometric spam inside Claude Code sessions. |

## Contributing

Issues and PRs welcome. Each plugin lives in its own directory under `plugins/` and is independently versioned via its `plugin.json`.

## License

[MIT](./LICENSE)
