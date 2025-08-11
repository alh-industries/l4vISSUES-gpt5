# l4vISSUES-gpt5

# GitHub Project Import (Scripts)

A small set of Bash scripts to import a planning TSV/CSV into GitHub:
- Create labels
- Create issues (from rows)
- Create sub-issues (parsed from parent issue body, `;` delimited)
- Create or reuse a GitHub Project (Projects, not Classic)
- Create project fields/options and apply values to items

## Order of operations
Run in this exact order:
1) aa-labels.sh — idempotent  
2) ab-issues.sh — create only (no idempotency)  
3) ac-subissues.sh — create only (no idempotency)  
4) ad-project.sh — idempotent (reuse or create project; avoid duplicate items)  
5) ae-fields.sh — idempotent (fields/options created only if missing; values reapplied safely)

Tip: use the convenience runner:
```
./run.sh
```

## Requirements
- Bash 4+ (macOS users: `brew install bash` and run with `/usr/local/bin/bash` or `/opt/homebrew/bin/bash`)
- GitHub CLI: `gh` (authenticated: `gh auth login`)
- `jq` installed (used by project/fields scripts)

## Quick start
```bash
# clone your repo and enter it
git clone https://github.com/<you>/<repo>.git
cd <repo>

# make scripts executable
chmod +x aa-labels.sh ab-issues.sh ac-subissues.sh ad-project.sh ae-fields.sh run.sh

# authenticate GH CLI (once per machine)
gh auth login

# set environment variables for this shell
export GH_REPO="<you>/<repo>"
export DATA_FILE="data/PLANNERv9.1.tsv"
export PROJECT_OWNER="@me"              # or your org name
export PROJECT_TITLE="Imported Plan"    # project name you want
# PROJECT_NUMBER will be shown/needed after ad-project.sh creates or finds the project

# run scripts in order
./aa-labels.sh
./ab-issues.sh
./ac-subissues.sh
./ad-project.sh
# After ad-project.sh, set the number it prints:
export PROJECT_NUMBER="<printed-number>"
./ae-fields.sh
```

## Data format (headers & mapping)
- Delimiter auto-detected: TSV by default; CSV if filename ends in `.csv`.
- Column detection is **case-insensitive, by substring**:
  - `*title*` → issue title (required for issues)
  - `*body*` → issue body (used for issues; passed verbatim)
  - `*label*` → one or more label columns (all values applied)
  - `PROJECT_FIELD_*[:TYPE]` → project fields
    - `TYPE` can be `SINGLE_SELECT`, `DATE`, or omitted (defaults to TEXT)
    - Example: `PROJECT_FIELD_PRIORITY:SINGLE_SELECT`, `PROJECT_FIELD_DUE:DATE`
- There is **no `LOCAL_ID`** column; your “primary” label column is `ISSUE_LABEL_0` (plus any others).

## Idempotency rules (as implemented)
- Labels: idempotent (skips existing labels)
- Issues: **create only** (no de-dupe; re-running will create duplicates)
- Sub-issues: **create only** (no de-dupe)
- Project: idempotent (reuses matching project title; avoids re-adding existing items)
- Project fields & options: idempotent (creates missing fields/options only)

## Body handling
- Issue bodies are written to a temp file and passed via `gh issue create --body-file <file>`.
- The TSV/CSV cell content is used **verbatim** (no splitting, escaping, or replacement).
- Sub-issues are derived from the **parent row’s body** by splitting on `;` **in the sub-issues script only**.

## Outputs
- ab-issues.sh writes a map: `issue_map.tsv` (Title, URL, Number)
- ac-subissues.sh writes a map: `subissue_map.tsv` (Parent Title, Child Title, Child URL, Child Number)
- You can move these into `output/` and add them to `.gitignore`.

## Running in a Codespace (optional)
- Open the repo → Code → Codespaces → Create codespace.
- In the terminal, set the env vars (same as above) and run the scripts in order.

## Common pitfalls
- Not authenticated: run `gh auth login`.
- Wrong repo: ensure `export GH_REPO="<you>/<repo>"` is set before running.
- Missing Bash 4+: install a newer bash and run the scripts with that interpreter.
- CSV with quoted commas: these scripts are tuned for TSV. If you must use CSV with complex quoting, consider converting to TSV first.

## Script reference (what each one does)
- aa-labels.sh  
  - Scans all `*label*` columns, builds a unique set, compares against existing labels via `gh label list`, and creates only missing labels (`gh label create <name>`). No color/description flags.
- ab-issues.sh  
  - Creates issues from each row using `*title*` and `*body*`; attaches all `*label*` values. Uses `--body-file` for an exact body. Produces `issue_map.tsv`.
- ac-subissues.sh  
  - For each parent issue (from `issue_map.tsv`), splits the parent row’s body on `;` and creates a child issue per token. Inherits row labels. Appends a task-list link to the parent body.
- ad-project.sh  
  - Finds or creates a project by `PROJECT_OWNER` + `PROJECT_TITLE`. Adds all parent and sub-issues as items, skipping URLs already present.
- ae-fields.sh  
  - Ensures project fields exist (and select options for `SINGLE_SELECT`). Applies values from `PROJECT_FIELD_*` columns to the corresponding items.

## .gitignore suggestion
```
output/
*.log
errors.md
*.tmp
.DS_Store
```
