# GitHub Project TSV Import Automation (Zero‑Edit)

This repo lets you import Labels, Issues, Sub‑issues, a Project, and Project Fields from a TSV/CSV **without editing any files**. You run it entirely from **GitHub → Actions → Run workflow**.

## 📂 Repo Layout
```
TSV_HERE/        # put your .tsv/.csv here
SCRIPTS/         # the five Bash scripts (already location-agnostic)
OUTPUTS/         # generated maps/outputs
.github/workflows/manual-import.yml  # prewired manual workflow
```

## 🧠 How it works (no edits required)
- Auth uses the built‑in **GITHUB_TOKEN** (auto‑injected by GitHub Actions).
- The workflow takes three inputs at run time:
  - `data_pattern` (glob, default `TSV_HERE/*.tsv`)
  - `project_owner` (`@me` for a user project, or your org name)
  - `project_title` (create or reuse)
- Toggles let you enable/disable each step (defaults are all **on**).
- Scripts discover columns by **case‑insensitive substring**:
  - `*title*`, `*body*`, `*label*`, and `PROJECT_FIELD_*[:TYPE]`

## ✅ One‑time repo setup (still zero edits)
1) Ensure your TSV/CSV files live in `TSV_HERE/`.
2) Confirm the workflow file exists at `.github/workflows/manual-import.yml`.
3) Repo → **Settings → Actions → General → Workflow permissions** → set **Read and write permissions**.

> Org projects: your org must allow `GITHUB_TOKEN` to write Projects. If it doesn’t, an org admin needs to enable that in org settings. You still don’t edit files here.

## ▶️ Running it from GitHub Web (every time)
1) Go to **Actions → Manual Import → Run workflow**.
2) Fill the three inputs:
   - **data_pattern**: keep default `TSV_HERE/*.tsv` (or adjust glob)
   - **project_owner**: `@me` (user project) or your **org** name
   - **project_title**: e.g., `Imported Plan`
3) Leave all toggles on (or switch off what you don’t need).
4) Click **Run workflow**.

**That’s it.** No edits to scripts or YAML.

## What the steps do
1) **Labels (idempotent)** — creates only missing labels.
2) **Issues (create‑only)** — creates issues; attaches all `*label*` columns; body passed verbatim via `--body-file`. Produces `OUTPUTS/issue_map.tsv`.
3) **Sub‑issues (create‑only)** — splits parent body on `;`, creates child issues, links them back. Produces `OUTPUTS/subissue_map.tsv`.
4) **Project (idempotent)** — creates or reuses project; adds all issue URLs; saves number to `OUTPUTS/project_number.txt`.
5) **Fields (idempotent)** — creates fields/options if missing; applies values from `PROJECT_FIELD_*[:TYPE]`.

## Notes
- TSV recommended. CSV with complex quoting isn’t fully parsed by Bash’s simple splitter.
- The workflow always picks the **latest modified** file matching your `data_pattern`.
- No `LOCAL_ID` is needed; your primary label column is `ISSUE_LABEL_0` (and friends).


--------------


# deprecated:



# GitHub Project TSV Import Automation

This repository contains a **modular, multi-step import system** for creating GitHub Labels, Issues, Sub-issues, Projects, and Project Fields from a TSV or CSV file.

## 📂 Repo Structure

```
TSV_HERE/        # Place your TSV or CSV data files here
SCRIPTS/         # Modular Bash scripts for each import stage
OUTPUTS/         # Generated during runs (maps, logs, outputs)
.github/
└── workflows/
    └── runALL.yml  # Manual trigger GitHub Action to run the scripts
```

## 🛠 Modular Script Flow

Scripts are intentionally **short, DRY, and modular**. Each does one thing, so you can run them separately or chain them via the included GitHub Action.

Order of operation (alphabetical naming keeps them in sequence):

1. **aa-labels.sh**  
   - Reads TSV/CSV  
   - Creates all unique labels (idempotent — no duplicates)  
   - Skips color and description (optional in GitHub CLI)

2. **ab-issues.sh**  
   - Reads TSV/CSV  
   - Creates issues and attaches labels  
   - **No idempotency** (one-off import)  

3. **ac-subissues.sh**  
   - Parses `ISSUE_BODY` column for `;`-delimited sub-issues  
   - Creates sub-issues  
   - Assigns labels and links to parent issues  
   - **No idempotency**  

4. **ad-project.sh**  
   - Creates or reuses a GitHub Project  
   - Adds all issues and sub-issues to the project  
   - Saves project number to `OUTPUTS/project_number.txt`

5. **ae-fields.sh**  
   - Reads TSV/CSV for project field definitions and options  
   - Creates project fields and options (idempotent)  
   - Updates field values for issues in the project

---

## ⚡ Running from GitHub Web

You can run the full pipeline **manually** via the `Manual Import` workflow.

### **One-time setup**
1. Ensure `.github/workflows/manual-import.yml` exists on your default branch.  
2. Put your TSV/CSV in `TSV_HERE/`.  
3. In repo settings → **Actions → General**, set:  
   > Workflow permissions → **Read and write permissions**  
4. (Org projects only) — Create a **classic PAT** with:
   - `repo`
   - `project`
   - `read:org`  
   Save it as a repo secret named `GH_PAT`.  
   In `.github/workflows/manual-import.yml`, set:
   ```yaml
   env:
     GH_TOKEN: ${{ secrets.GH_PAT }}
   ```
   If using **@me** for a user project, `GITHUB_TOKEN` works without a PAT.

---

### **Every run**
Go to **Actions → Manual Import → Run workflow**. Fill in:

| Field           | Description                                                                 |
|-----------------|-----------------------------------------------------------------------------|
| **data_pattern** | Glob for your TSV/CSV. Default: `TSV_HERE/*.tsv`                           |
| **project_owner**| `@me` (user project) or org name                                            |
| **project_title**| Name of the project. Creates if not found, reuses if exists                 |
| **run_labels**   | Whether to run label creation step (default: true)                          |
| **run_issues**   | Whether to run issue creation step (default: true)                          |
| **run_subissues**| Whether to run sub-issue creation step (default: true)                      |
| **run_project**  | Whether to run project create/reuse step (default: true)                    |
| **run_fields**   | Whether to run field creation step (default: true)                          |

**Important:** If you turn off `run_project`, also turn off `run_fields` — fields need the project from the same run.

---

### **What you don’t need to enter**
- **GH_REPO** — auto-set by the workflow
- **PROJECT_NUMBER** — auto-detected from the created/reused project
- **Script paths** — workflow handles them
- **Auth during run** — handled via GH_TOKEN or GH_PAT

---

## 📌 Example

Example run to import the latest `.tsv` from `TSV_HERE/` into a user project called "Imported Plan":

1. Upload `plan.tsv` to `TSV_HERE/`
2. Go to **Actions → Manual Import → Run workflow**
3. Set:
   ```
   data_pattern: TSV_HERE/*.tsv
   project_owner: @me
   project_title: Imported Plan
   ```
4. Leave all toggles checked
5. Click **Run workflow**

---

## 🔗 GitHub CLI Reference

These scripts use [`gh`](https://cli.github.com/manual/) commands:
- [`gh label create`](https://cli.github.com/manual/gh_label_create)
- [`gh issue create`](https://cli.github.com/manual/gh_issue_create)
- [`gh issue edit`](https://cli.github.com/manual/gh_issue_edit)
- [`gh project create`](https://cli.github.com/manual/gh_project_create)
- [`gh project item-create`](https://cli.github.com/manual/gh_project_item_create)
- [`gh project field-create`](https://cli.github.com/manual/gh_project_field_create)
- [`gh project option-create`](https://cli.github.com/manual/gh_project_option_create)
- [`gh project item-edit`](https://cli.github.com/manual/gh_project_item_edit)

All scripts auto-detect `.tsv` vs `.csv` and match columns by **case-insensitive substring** in header names.

---



---------

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
