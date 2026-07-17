#!/bin/bash

set -e

VERSION="2.0.0"

show_help() {
    echo "Dependings v$VERSION"
    echo ""
    echo "Usage: dependings [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run          Perform a dry run without making any changes."
    echo "  --close-prs        Close the open Dependabot PRs after merging."
    echo "  --no-pr            Apply changes directly to the current branch (no push, no PR)."
    echo "  --delete-branch    Delete the staging branch after the PR is created (ignored with --no-pr)."
    echo "  --help             Display this help message."
    echo ""
    echo "Description:"
    echo "Dependings cherry-picks all open Dependabot PRs onto the current branch."
    echo ""
    echo "Default mode: creates a new branch with the current timestamp, cherry-picks all"
    echo "open Dependabot PRs into it, pushes the branch to origin, and creates a PR with"
    echo "a detailed message including links to the original Dependabot PRs."
    echo ""
    echo "With --no-pr: cherry-picks all Dependabot PRs directly onto the current branch"
    echo "without pushing or creating a PR."
    echo ""
    echo "Requires git and gh to be installed and configured."
}

is_merged() {
    local branch=$1
    git branch --merged | grep -q "$branch"
}

log() {
    local message=$1
    echo "[INFO] $message"
}

handle_cherry_pick_conflicts() {
    local pr_title=$1

    log "Merge conflicts detected while cherry-picking: $pr_title"

    conflicted_files=$(git status --porcelain | grep "^UU\|^AA\|^DD" | cut -c4-)

    if [ -z "$conflicted_files" ]; then
        log "No conflicted files found, continuing..."
        return 0
    fi

    echo "Conflicted files:"
    echo "$conflicted_files"
    echo ""

    while true; do
        echo "Choose an action:"
        echo "1) Open conflicted files in editor and resolve manually"
        echo "2) Skip this PR and continue with others"
        echo "3) Abort the entire process"
        read -p "Enter your choice (1-3): " choice </dev/tty

        case $choice in
            1)
                editor="${EDITOR:-vim}"
                echo "$conflicted_files" | while IFS= read -r file; do
                    if [ -n "$file" ]; then
                        log "Opening $file in $editor"
                        $editor "$file" </dev/tty >/dev/tty
                    fi
                done

                log "Staging resolved conflicts and continuing cherry-pick..."
                git add .
                if git cherry-pick --continue --no-edit; then
                    log "Cherry-pick continued successfully"
                    return 0
                else
                    remaining_conflicts=$(git status --porcelain | grep "^UU\|^AA\|^DD" | wc -l)
                    if [ "$remaining_conflicts" -gt 0 ]; then
                        echo "There are still unresolved conflicts. Please resolve them and try again."
                        continue
                    else
                        log "No conflicts found but cherry-pick failed for another reason."
                        return 1
                    fi
                fi
                ;;
            2)
                log "Skipping PR: $pr_title"
                git cherry-pick --abort
                return 1
                ;;
            3)
                log "Aborting entire process"
                git cherry-pick --abort
                exit 1
                ;;
            *)
                echo "Invalid choice. Please enter 1, 2, or 3."
                ;;
        esac
    done
}

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "[ERROR] Dependings must be run inside a Git repository."
    show_help;
    exit 1
fi

timestamp=$(date +%Y%m%d%H%M%S)

dry_run=false
close_prs=false
delete_branch=false
no_pr=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --dry-run) dry_run=true ;;
        --close-prs) close_prs=true ;;
        --delete-branch) delete_branch=true ;;
        --no-pr) no_pr=true ;;
        --help) show_help; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; show_help; exit 1 ;;
    esac
    shift
done

log "Starting Dependings v$VERSION..."

log "Fetching all branches and PRs"
if [ "$dry_run" = false ]; then
    git fetch origin
fi

if [ "$no_pr" = false ]; then
    bump_deps_branch="bump-deps-$timestamp"
    log "Creating new branch $bump_deps_branch"
    if [ "$dry_run" = false ]; then
        git checkout -b "$bump_deps_branch"
    fi
else
    log "Running in --no-pr mode: cherry-picking directly onto current branch ($(git branch --show-current))"
fi

log "Getting the list of open Dependabot PRs"
dependabot_prs=$(gh pr list --state open --author app/dependabot --json number,headRefName,title,url | jq -c '.[]')

successful_prs_file=$(mktemp)
skipped_prs_file=$(mktemp)

while IFS= read -r pr; do
    if [ -z "$pr" ]; then
        continue
    fi

    pr_branch=$(echo "$pr" | jq -r '.headRefName')
    pr_title=$(echo "$pr" | jq -r '.title')
    dependabot_branch="origin/$pr_branch"

    if is_merged "$dependabot_branch"; then
        log "Branch $dependabot_branch is already merged, skipping..."
        continue
    fi

    # Find commits on the Dependabot branch not on main
    merge_base=$(git merge-base HEAD "origin/$pr_branch")
    commits=$(git log --reverse --format="%H" "$merge_base..origin/$pr_branch")

    if [ -z "$commits" ]; then
        log "No new commits found in $pr_branch, skipping..."
        continue
    fi

    log "Cherry-picking $pr_title"
    if [ "$dry_run" = false ]; then
        pick_failed=false
        while IFS= read -r commit; do
            if ! git cherry-pick "$commit"; then
                if handle_cherry_pick_conflicts "$pr_title"; then
                    log "Successfully resolved conflicts for $pr_title"
                else
                    log "Skipped $pr_title due to conflicts"
                    pick_failed=true
                    break
                fi
            fi
        done <<< "$commits"

        if [ "$pick_failed" = false ]; then
            log "Successfully cherry-picked $pr_title"
            echo "$pr" >> "$successful_prs_file"
        else
            echo "$pr" >> "$skipped_prs_file"
        fi
    else
        log "Dry run: would cherry-pick $pr_title"
        echo "$pr" >> "$successful_prs_file"
    fi
done <<< "$dependabot_prs"

successful_prs=$(cat "$successful_prs_file")
skipped_prs=$(cat "$skipped_prs_file")
rm "$successful_prs_file" "$skipped_prs_file"

if [ "$no_pr" = false ]; then
    log "Rebasing origin/main onto $bump_deps_branch"
    if [ "$dry_run" = false ]; then
        git rebase origin/main || {
            log "Rebase of origin/main failed - resolve conflicts manually and re-run"
            exit 1
        }
    else
        log "Dry run: would rebase origin/main onto current branch"
    fi

    log "Pushing the $bump_deps_branch branch to origin"
    if [ "$dry_run" = false ]; then
        git push origin "$bump_deps_branch" || {
            log "Failed to push branch $bump_deps_branch"
            exit 1
        }
    fi

    pr_body="This PR includes the following Dependabot updates:

## Successfully Cherry-picked PRs
$(echo "$successful_prs" | while IFS= read -r pr; do
    if [ -n "$pr" ]; then
        pr_title=$(echo "$pr" | jq -r '.title')
        pr_url=$(echo "$pr" | jq -r '.url')
        echo "- [$pr_title]($pr_url)"
    fi
done)

$(if [ -n "$skipped_prs" ]; then
    echo "## Skipped PRs (due to merge conflicts)"
    echo "$skipped_prs" | while IFS= read -r pr; do
        if [ -n "$pr" ]; then
            pr_title=$(echo "$pr" | jq -r '.title')
            pr_url=$(echo "$pr" | jq -r '.url')
            echo "- [$pr_title]($pr_url)"
        fi
    done
fi)
"

    log "Creating a new PR"
    if [ "$dry_run" = false ]; then
        pr_output=$(gh pr create --title "Bump dependencies - $timestamp" --body "$pr_body")
        created_pr_url=$(echo "$pr_output" | grep -o 'https://github.com/[^ ]*')
        log "Created PR: $created_pr_url"
    fi

    git checkout main

    if [ "$delete_branch" = true ] && [ "$dry_run" = false ]; then
        log "Deleting local branch $bump_deps_branch"
        git branch -D "$bump_deps_branch" || {
            log "Failed to delete branch $bump_deps_branch"
            exit 1
        }
    fi
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

# Generate final report
successful_count=0
if [ -n "$successful_prs" ]; then
    successful_count=$(echo "$successful_prs" | grep -c '^{' 2>/dev/null || echo "0")
fi

skipped_count=0
if [ -n "$skipped_prs" ]; then
    skipped_count=$(echo "$skipped_prs" | grep -c '^{' 2>/dev/null || echo "0")
fi

log "=== FINAL REPORT ==="
log "Successfully cherry-picked: $successful_count PRs"
if [ "$skipped_count" -gt 0 ]; then
    log "Skipped due to conflicts: $skipped_count PRs"
fi
log "All tasks completed successfully!"
