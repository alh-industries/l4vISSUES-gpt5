# GitHub Project TSV Import Automation

Automates label, issue, sub-issue and project creation from a TSV/CSV.

## Layout
| Path | Role |
| --- | --- |
| `TSV_HERE/` | place input `.tsv`/`.csv` files |
| `SCRIPTS/` | bash scripts |
| `OUTPUTS/` | generated maps & logs |
| `.github/workflows/` | GitHub Actions workflows |

## Script Catalog
| Script | Role | Inputs | Outputs |
|---|---|---|---|
| `aa-labels.sh` | create missing labels | TSV/CSV | — |
| `ab-issues.sh` | create issues | TSV/CSV | `OUTPUTS/issue_map.tsv` |
| `ac-subissues.sh` | create sub-issues from parent body | TSV/CSV + `issue_map.tsv` | `OUTPUTS/subissue_map.tsv` |
| `ad-project.sh` | create/reuse project & add items | `issue_map.tsv`, `subissue_map.tsv` | `OUTPUTS/project_number.txt` |
| `ae-fields.sh` | ensure project fields & set values | TSV/CSV + `project_number.txt` + `issue_map.tsv` | — |
| `ba-link-subissues.sh` | link task-list refs as sub-issues | repository issues via API | — |
| `logging.sh` | shared log helpers | called internally | `OUTPUTS/errors.md`, `OUTPUTS/info.md` |
| `purge_ALL-localrun.sh` | delete all issues and labels (danger) | user confirmation | — |

## Workflows
| Workflow | Purpose |
|---|---|
| `manual-import-v3.yml` | run selected scripts from the web UI (`run_all` or toggles) |
| `link-subissues.yml` | scan issues and link task-list references |
| `template.yml` | example workflow (unused) |

## Data Flow
```
TSV/CSV
  ├─ aa-labels.sh
  ├─ ab-issues.sh ─┐
  ├─ ac-subissues.sh ─┤→ OUTPUTS/{issue_map.tsv, subissue_map.tsv}
  ├─ ad-project.sh ─┐ └→ OUTPUTS/project_number.txt
  └─ ae-fields.sh ──┘    (requires project_number + issue_map)
```

## Run from GitHub
1. Upload your data file to `TSV_HERE/`.
2. Actions → **Manual Import v3** → **Run workflow**.
3. Provide `data_pattern`, `project_owner` (optional), and `project_title`.
4. Enable `run_all` or toggle individual steps.
5. Outputs appear under `OUTPUTS/` and are committed back.

## Local Run (optional)
```
chmod +x SCRIPTS/*.sh
export DATA_FILE=TSV_HERE/your.tsv
./SCRIPTS/aa-labels.sh
./SCRIPTS/ab-issues.sh
./SCRIPTS/ac-subissues.sh
PROJECT_TITLE="My Project" ./SCRIPTS/ad-project.sh
./SCRIPTS/ae-fields.sh
```

## Notes
- Headers match by case-insensitive substring (`*title*`, `*body*`, `*label*`, `PROJECT_FIELD_*[:TYPE]`).
- TSV preferred; CSV supported.
- Requires Bash 4+, `gh` CLI, and `jq` for local runs.

