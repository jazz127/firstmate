# Local CLI verification

These commands used the running Firstmate shell interfaces and disposable local files. No vendor CLI, Herdr server, shared daemon, or production credential was accessed.

Command: `bash ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/bin/fm-busy-event.sh arm ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/home/state task`

Exit: 0

```text
g1792371993.77835.16344

```

Command: `bash ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/bin/fm-busy-event.sh apply ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/home/state task idle --gen g1792371993.77835.16344 --if-seq 1 --source fm-interrupt --event interrupt --turn-ended`

Exit: 1

```text
error: stale busy-state sequence for task (event rejected)

```

Command: `bash ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/bin/fm-busy-event.sh arm ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/home/state task`

Exit: 0

```text
g1792371993.78010.2457

```

Command: `bash ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/bin/fm-busy-event.sh apply ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/home/state task idle --gen g1792371993.77835.16344 --if-seq 1 --source fm-interrupt --event interrupt`

Exit: 1

```text
error: stale busy-state gen for task (event rejected)

```

## Conditional close preserves newer sequence and generation; matching close advances sequence and house timestamp

```json
{
  "scenario": "Conditional close preserves newer sequence and generation; matching close advances sequence and house timestamp",
  "before": "v1 gen=g1792371993.77835.16344 seq=2 state=busy source=polytoken-hook event=pre-user-prompt ts=1792371993\n",
  "closed": "v1 gen=g1792371993.77835.16344 seq=3 state=idle source=fm-interrupt event=interrupt ts=1792371993\n",
  "rearmed": "v1 gen=g1792371993.78010.2457 seq=1 state=busy source=fm-spawn event=launch-brief ts=1792371993\n"
}
```

Command: `ruby -ryaml -rjson -e puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true)) ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/anchored/config.yaml`

Exit: 0

```text
{"version":4,"providers":{"fixture":{"api_key":"disposable-config-value"}},"default_permission_matcher":"bypass_plus"}

```

## Mirror permission policy and provider configuration

```json
{
  "scenario": "Mirror permission policy and provider configuration",
  "case": "anchored",
  "generated": {
    "version": 4,
    "providers": {
      "fixture": {
        "api_key": "disposable-config-value"
      }
    },
    "default_permission_matcher": "bypass_plus"
  }
}
```

Command: `ruby -ryaml -rjson -e puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true)) ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/alias/config.yaml`

Exit: 0

```text
{"version":4,"providers":{"fixture":{"api_key":"disposable-config-value"}},"policy":"bypass_plus","default_permission_matcher":"bypass_plus"}

```

## Mirror permission policy and provider configuration

```json
{
  "scenario": "Mirror permission policy and provider configuration",
  "case": "alias",
  "generated": {
    "version": 4,
    "providers": {
      "fixture": {
        "api_key": "disposable-config-value"
      }
    },
    "policy": "bypass_plus",
    "default_permission_matcher": "bypass_plus"
  }
}
```

Command: `ruby -ryaml -rjson -e puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true)) ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/prompt/config.yaml`

Exit: 0

```text
{"version":4,"providers":{"fixture":{"api_key":"disposable-config-value"}},"default_permission_matcher":"bypass"}

```

## Mirror permission policy and provider configuration

```json
{
  "scenario": "Mirror permission policy and provider configuration",
  "case": "prompt",
  "generated": {
    "version": 4,
    "providers": {
      "fixture": {
        "api_key": "disposable-config-value"
      }
    },
    "default_permission_matcher": "bypass"
  }
}
```

Command: `bash ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/bin/fm-herdr-groups.sh sidebar-config --apply ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/herdr-config.toml`

Exit: 0

```text
appended the project-group sidebar rows to ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/herdr-config.toml (backup: ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/herdr-config.toml.bak-1792371993); run `herdr server reload-config` to apply them

```

Command: `bash ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/bin/fm-herdr-groups.sh sidebar-config --apply ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/herdr-config.toml`

Exit: 1

```text
fm-herdr-groups: ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/herdr-config.toml already defines Herdr sidebar rows; merge the suggested rows by hand (fm-herdr-groups.sh sidebar-config prints them)

```

## Apply sidebar configuration once, preserving exact backup bytes

```json
{
  "scenario": "Apply sidebar configuration once, preserving exact backup bytes",
  "generated": {
    "ui": {
      "agent_panel_sort": "spaces",
      "sidebar": {
        "spaces": {
          "rows": [
            [
              "state_icon",
              "workspace"
            ],
            [
              {
                "token": "$fm_group",
                "bold": true
              },
              "$fm_state"
            ]
          ]
        },
        "agents": {
          "rows": [
            [
              "state_icon",
              {
                "token": "$fm_group",
                "bold": true
              },
              "$fm_state",
              "$fm_task"
            ]
          ]
        }
      }
    }
  }
}
```

Command: `bash ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/bin/fm-herdr-groups.sh plan`

Exit: 0

```text
api-done	Web	done	001.Web.4.api-done	001.Web
other-fail	Other	problem	002.Other.2.other-fail	002.Other
shop-ask	Web	needs-captain	001.Web.1.shop-ask	001.Web
shop-run	Web	running	001.Web.3.shop-run	001.Web

```

## Opt-in group plan sorts decisions before running and completed tasks, preserving rule order

```json
{
  "scenario": "Opt-in group plan sorts decisions before running and completed tasks, preserving rule order",
  "plan": "api-done\tWeb\tdone\t001.Web.4.api-done\t001.Web\nother-fail\tOther\tproblem\t002.Other.2.other-fail\t002.Other\nshop-ask\tWeb\tneeds-captain\t001.Web.1.shop-ask\t001.Web\nshop-run\tWeb\trunning\t001.Web.3.shop-run\t001.Web\n"
}
```

Command: `bash -c . "$1"; fm_polytoken_write_facet "$2" "$3" _ ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/bin/fm-polytoken-lib.sh ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/project ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/home/state/task.inbox`

Exit: 1

```text
error: ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/project/.polytoken/facets/firstmate-worker.md already exists; project-owned polytoken wiring is not firstmate's to clobber. Select another harness for this task.

```

Command: `bash -c . "$1"; fm_polytoken_write_facet "$2" "$3" _ ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/bin/fm-polytoken-lib.sh ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/project ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/home/state/task.inbox`

Exit: 1

```text
error: ~/.no-mistakes/worktrees/119cd7a6b9a4/01M58R1EZXH295XPPYJMZP2JTS/.test-runtime/local/project/.polytoken/facets/firstmate-worker.md already exists; project-owned polytoken wiring is not firstmate's to clobber. Select another harness for this task.

```

## Facet writer refuses existing files and symlinks while preserving exact project-owned bytes

```json
{
  "scenario": "Facet writer refuses existing files and symlinks while preserving exact project-owned bytes",
  "bytes": "project-owned facet\n\n"
}
```

