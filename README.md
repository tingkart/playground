# highch-art plugin

Claude Code plugin for a highch.art workspace. It ships the `highch-art` skill and its `highchart.sh` helper.

## Install

```
/plugin marketplace add tingkart/playground
/plugin install highch-art@highch-art
```

The repo is private, so installing needs read access to `tingkart/playground` through `gh` or SSH. For background auto-update, set `GITHUB_TOKEN` or `GH_TOKEN`.

## Connect

The plugin carries no credentials. In the workspace, click "Copy prompt for your agent" and paste it into the agent. It contains the URL and a revocable API key for the session. For terminal use, export `HIGHCHART_URL` and `HIGHCHART_API_KEY`.

## Updating

The skill files are copied from the app repo (`public/skills/highch-art/`). Copy them again, bump `version` in `plugins/highch-art/.claude-plugin/plugin.json`, and push.
