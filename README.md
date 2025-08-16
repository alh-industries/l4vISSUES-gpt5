# GitHub Project TSV Import Automation

Automates label, issue, sub-issue and project creation from a TSV.

## Quick Links
 
| Workflows | Scripts | Outputs | Paths |
| --- | --- | --- | --- |
| [`manual-import-v3.yml`](.github/workflows/manual-import-v3.yml)<br>[`link-subissues.yml`](.github/workflows/link-subissues.yml)<br>[`template.yml`](.github/workflows/template.yml) | [`aa-labels.sh`](SCRIPTS/aa-labels.sh)<br>[`ab-issues.sh`](SCRIPTS/ab-issues.sh)<br>[`ac-subissues.sh`](SCRIPTS/ac-subissues.sh)<br>[`ad-project.sh`](SCRIPTS/ad-project.sh)<br>[`ae-fields.sh`](SCRIPTS/ae-fields.sh)<br>[`ba-link-subissues.sh`](SCRIPTS/ba-link-subissues.sh)<br>[`logging.sh`](SCRIPTS/logging.sh)<br>[`purge_ALL-localrun.sh`](SCRIPTS/purge_ALL-localrun.sh) | [`issue_map.tsv`](OUTPUTS/issue_map.tsv)<br>[`subissue_map.tsv`](OUTPUTS/subissue_map.tsv)<br>[`project_number.txt`](OUTPUTS/project_number.txt)<br>[`errors.md`](OUTPUTS/errors.md)<br>[`info.md`](OUTPUTS/info.md) | [`TSV_HERE/`](TSV_HERE/)<br>[`OUTPUTS/`](OUTPUTS/)<br>[`SCRIPTS/`](SCRIPTS/)<br>[`.github/workflows/`](.github/workflows/) |

## Script Catalog
| Script | Role | Inputs | Outputs |
|---|---|---|---|
| [`aa-labels.sh`](SCRIPTS/aa-labels.sh) | create missing labels | TSV | — |
| [`ab-issues.sh`](SCRIPTS/ab-issues.sh) | create issues | TSV | [`OUTPUTS/issue_map.tsv`](OUTPUTS/issue_map.tsv) |
| [`ac-subissues.sh`](SCRIPTS/ac-subissues.sh) | create sub-issues from parent body | TSV + [`issue_map.tsv`](OUTPUTS/issue_map.tsv) | [`OUTPUTS/subissue_map.tsv`](OUTPUTS/subissue_map.tsv) |
| [`ad-project.sh`](SCRIPTS/ad-project.sh) | create/reuse project & add items | [`issue_map.tsv`](OUTPUTS/issue_map.tsv), [`subissue_map.tsv`](OUTPUTS/subissue_map.tsv) | [`OUTPUTS/project_number.txt`](OUTPUTS/project_number.txt) |
| [`ae-fields.sh`](SCRIPTS/ae-fields.sh) | ensure project fields & set values | TSV + [`project_number.txt`](OUTPUTS/project_number.txt) + [`issue_map.tsv`](OUTPUTS/issue_map.tsv) | — |
| [`ba-link-subissues.sh`](SCRIPTS/ba-link-subissues.sh) | link task-list refs as sub-issues | repository issues via API | — |
| [`logging.sh`](SCRIPTS/logging.sh) | shared log helpers | called internally | [`OUTPUTS/errors.md`](OUTPUTS/errors.md), [`OUTPUTS/info.md`](OUTPUTS/info.md) |
| [`purge_ALL-localrun.sh`](SCRIPTS/purge_ALL-localrun.sh) | delete all issues and labels (danger) | user confirmation | — |

## Workflows
| Workflow | Purpose |
|---|---|
| [`manual-import-v3.yml`](.github/workflows/manual-import-v3.yml) | run selected scripts from the web UI (`run_all` or toggles) |
| [`link-subissues.yml`](.github/workflows/link-subissues.yml) | scan issues and link task-list references |
| [`template.yml`](.github/workflows/template.yml) | example workflow (unused) |

## Data Flow
```
TSV
  ├─ aa-labels.sh
  ├─ ab-issues.sh ─┐
  ├─ ac-subissues.sh ─┤→ OUTPUTS/{issue_map.tsv, subissue_map.tsv}
  ├─ ad-project.sh ─┐ └→ OUTPUTS/project_number.txt
  └─ ae-fields.sh ──┘    (requires project_number + issue_map)
```

## Run from GitHub
1. Upload your data file to [`TSV_HERE/`](TSV_HERE/).
2. Actions → **Manual Import v3** → **Run workflow**.
3. Provide `project_owner` (optional) and `project_title`.
4. Enable `run_all` or toggle individual steps.
5. Outputs appear under [`OUTPUTS/`](OUTPUTS/) and are committed back.

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
- TSV only.
- Requires Bash 4+, `gh` CLI, and `jq` for local runs.
