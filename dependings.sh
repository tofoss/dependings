#!/bin/bash

set -e

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run          Perform a dry run without making any changes."
    echo "  --close-prs        Close the open Dependabot PRs after creating the new PR."
    echo "  --delete-branch    Delete the local branch after it is pushed."
    echo "  --help             Display this help message."
    echo ""
    echo "Description:"
    echo "This script creates a new branch with the current timestamp, rebases all open Dependabot PRs into it,"
    echo "pushes the branch to origin, creates a PR with a detailed message including links to the original Dependabot PRs,"
    echo "and then optionally closes the open Dependabot PRs and deletes the local branch."
}

is_merged() {
    local branch=$1
    git branch --merged | grep -q "$branch"
}

log() {
    local message=$1
    echo "[INFO] $message"
}

timestamp=$(date +%Y%m%d%H%M%S)

dry_run=false
close_prs=false
delete_branch=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --dry-run) dry_run=true ;;
        --close-prs) close_prs=true ;;
        --delete-branch) delete_branch=true ;;
        --help) show_help; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; show_help; exit 1 ;;
    esac
    shift
done

log "Starting the bump dependencies script..."

branch_name="bump-deps-$timestamp"
log "Creating new branch $branch_name"
if [ "$dry_run" = false ]; then
    git checkout -b "$branch_name"
fi

log "Fetching all branches and PRs"
if [ "$dry_run" = false ]; then
    git fetch origin
fi

log "Getting the list of open Dependabot PRs"
dependabot_prs=$(gh pr list --state open --author app/dependabot --json number,headRefName,title,url | jq -c '.[]')

echo "$dependabot_prs" | while IFS= read -r pr; do
    pr_branch=$(echo "$pr" | jq -r '.headRefName')
    branch_name="origin/$pr_branch"
    
    if is_merged "$branch_name"; then
        log "Branch $branch_name is already merged, skipping..."
        continue
    fi
    
    log "Rebasing branch $branch_name onto $branch_name"
    if [ "$dry_run" = false ]; then
        git rebase "$branch_name"
    fi
done

log "Pushing the bump-deps branch to origin"
if [ "$dry_run" = false ]; then
    git push origin "$branch_name"
fi

pr_body="This PR includes the following Dependabot updates rebased into the bump-deps-$timestamp branch:

$(echo "$dependabot_prs" | while IFS= read -r pr; do
    pr_title=$(echo "$pr" | jq -r '.title')
    pr_url=$(echo "$pr" | jq -r '.url')
    echo "- [$pr_title]($pr_url)"
done)
"

log "Creating a new PR"

if [ "$dry_run" = false ]; then
    pr_output=$(gh pr create --title "Bump Dependencies - $timestamp" --body "$pr_body")
    created_pr_url=$(echo "$pr_output" | grep -o 'https://github.com/[^ ]*')
    log "Created PR: $created_pr_url"
fi

if [ "$close_prs" = true ]; then
    echo "$dependabot_prs" | while IFS= read -r pr; do
        pr_number=$(echo "$pr" | jq -r '.number')
        
        if [ "$dry_run" = false ]; then
            log "Closing PR $pr_number"
            gh pr close "$pr_number"
        else
            log "Dry run: would close PR $pr_number"
        fi
    done
fi

git checkout main

if [ "$delete_branch" = true ]; then
    log "Deleting local branch $branch_name"
    if [ "$dry_run" = false ]; then
        git branch -D "$branch_name"
    else
        log "Dry run: would delete local branch $branch_name"
    fi
fi

log "All tasks completed successfully!"
