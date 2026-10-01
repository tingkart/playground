# highch-art plugin

Claude Code plugin for a highch.art workspace. It ships the `highch-art` skill and its `highchart.sh` helper.

## Install

```
/plugin marketplace add YOUR_GITHUB_USER/highch-art-plugin
/plugin install highch-art@highch-art
```

## Connect

The plugin carries no credentials. In the workspace, click "Copy prompt for your agent" and paste it into the agent. It contains the URL and a revocable API key for the session. For terminal use, export `HIGHCHART_URL` and `HIGHCHART_API_KEY`.

## Updating

The skill files are copied from the app repo (`public/skills/highch-art/`). Copy them again, bump `version` in `plugins/highch-art/.claude-plugin/plugin.json`, and push.
