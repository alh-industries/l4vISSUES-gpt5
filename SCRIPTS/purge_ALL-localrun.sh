#!/bin/bash
# ===================================================================================
#
# DANGER: THIS SCRIPT DELETES REPOSITORY ISSUES AND/OR LABELS.
# Version: 3.0 - Combines issue and label deletion into a single script.
#
# This script must be run manually from your local machine.
#
# ===================================================================================

# --- Section 1: Delete All Issues ---
#!/bin/bash

echo
echo "==========================================================="
echo "WARNING: This will permanently delete ALL Issues and Labels from the repository."
read -p "Do you want to proceed? (y/n) " -n 1 -r
echo # Move to a new line

if [[ $REPLY =~ ^[Yy]$ ]]; then
  # --- Issue Deletion Block ---
  echo "Fetching and deleting all issues..."
  gh issue list --state all --limit 9999 --json number -q '.[].number' | while read -r issue_number; do
    echo "Deleting issue #${issue_number}..."
    gh issue delete "$issue_number" --yes
    sleep 1
  done # <-- This 'done' now correctly ends the issue deletion loop.
  
  echo "All issues have been purged."
  echo # Add a space for readability

  # --- Label Deletion Block ---
  echo "Fetching and deleting all labels..."
  gh label list --limit 1000 --json name -q '.[].name' | while read -r label_name; do
    echo "Deleting label '${label_name}'..."
    gh label delete "$label_name" --yes
    sleep 1
  done

  echo "All labels have been purged."
  echo
  echo "Purge complete."

else
  echo "Skipping deletion."
fi