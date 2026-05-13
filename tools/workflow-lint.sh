#!/bin/bash
set -euo pipefail

# Workflow linter for AI-Centered Development
# Mechanically enforces rules declared in AI_WORKFLOW.md
# All checks are warnings only (exit 0)

# Colors
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

MODE=""
PR_TITLE=""
PR_BODY=""
WARN_COUNT=0
FIXABLE_WARN_COUNT=0
ADVISORY_WARN_COUNT=0
DIFF_CHECKS_AVAILABLE=true
CHANGED_FILES=""
DELETED_FILES=""
NAME_STATUS=""

usage() {
    echo "Usage: $0 --mode=pre-push|ci [--pr-title=TITLE] [--pr-body=BODY]" >&2
    exit 1
}

emit_warning() {
    local warning_class="$1"
    local finding="$2"
    local why="$3"
    local fix="${4:-}"
    local normalized_class="$warning_class"

    WARN_COUNT=$((WARN_COUNT + 1))

    case "$normalized_class" in
        fixable)
            FIXABLE_WARN_COUNT=$((FIXABLE_WARN_COUNT + 1))
            ;;
        advisory)
            ADVISORY_WARN_COUNT=$((ADVISORY_WARN_COUNT + 1))
            ;;
        *)
            echo "Internal warning: unknown workflow-lint warning class '${warning_class}', treating it as advisory" >&2
            normalized_class="advisory"
            ADVISORY_WARN_COUNT=$((ADVISORY_WARN_COUNT + 1))
            ;;
    esac

    echo -e "${YELLOW}[WARN:${normalized_class}]${NC} ${finding}" >&2
    echo "  WHY: ${why}" >&2
    if [ "$normalized_class" = "fixable" ] && [ -n "$fix" ]; then
        echo "  FIX: ${fix}" >&2
    fi
}

info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

active_workflow_filename_regex() {
    echo '^([0-9]{4}|[1-9][0-9]{4,})-[a-z0-9]([a-z0-9-]*[a-z0-9])?\.md$'
}

resolve_exec_plan_paths() {
    local plan_name="$1"
    local todo_match=""
    local done_match=""
    local path=""

    while IFS= read -r path; do
        [ -z "$path" ] && continue
        case "$path" in
            docs/exec-plan/todo/*)
                if [ -z "$todo_match" ]; then
                    todo_match="$path"
                fi
                ;;
            docs/exec-plan/done/*)
                if [ -z "$done_match" ]; then
                    done_match="$path"
                fi
                ;;
        esac
    done < <(
        find docs/exec-plan/todo docs/exec-plan/done -maxdepth 1 -type f \
            \( -name "*-${plan_name}.md" -o -name "${plan_name}.md" \) \
            | sort
    )

    printf '%s|%s\n' "$todo_match" "$done_match"
}

current_exec_plan_paths() {
    local branch
    branch=$(current_branch)

    if ! echo "$branch" | grep -qE "^(feat|fix)/"; then
        return
    fi

    local plan_name="${branch#*/}"
    resolve_exec_plan_paths "$plan_name"
}

extract_linked_issue_paths_from_plan() {
    local plan_file="$1"

    [ -f "$plan_file" ] || return

    awk '
        function emit_paths(text) {
            gsub(/`/, "", text)
            while (match(text, /docs\/issues\/[A-Za-z0-9._-]+\.md/)) {
                print substr(text, RSTART, RLENGTH)
                text = substr(text, RSTART + RLENGTH)
            }
        }

        /^Addresses:/ {
            emit_paths($0)
        }
    ' "$plan_file"
}

pr_body_justifies_open_issue() {
    local issue_file="$1"

    if [ "$MODE" != "ci" ] || [ -z "$PR_BODY" ]; then
        return 1
    fi

    printf '%s\n' "$PR_BODY" | awk -v issue_file="$issue_file" '
        BEGIN {
            IGNORECASE = 1
        }

        index($0, issue_file) && $0 ~ /(remain(s)? open|left open|stays open|intentionally open)/ {
            found = 1
        }

        END {
            exit(found ? 0 : 1)
        }
    '
}

diff_includes_rename() {
    local old_path="$1"
    local new_path="$2"

    printf '%s\n' "$NAME_STATUS" | awk -v old_path="$old_path" -v new_path="$new_path" '
        $1 ~ /^R[0-9]+$/ && $2 == old_path && $3 == new_path {
            found = 1
        }
        END {
            exit(found ? 0 : 1)
        }
    '
}

check_active_filename_format() {
    local dir_path="$1"
    local label="$2"
    local file=""
    local base_name=""
    local pattern
    pattern=$(active_workflow_filename_regex)

    while IFS= read -r file; do
        [ -z "$file" ] && continue
        base_name=$(basename "$file")
        [ "$base_name" = "README.md" ] && continue

        if ! printf '%s\n' "$base_name" | grep -qE "$pattern"; then
            emit_warning \
                "fixable" \
                "Active ${label} file '${file}' does not use the required <sequence>-<name>.md format" \
                "Active workflow files carry durable ordering and branch-to-file mapping through the numbered filename convention (AI_WORKFLOW.md Active Plan / Issue Naming)." \
                "Rename it to '<sequence>-<name>.md' using the next correct sequence while keeping the '-<name>.md' suffix stable."
        fi
    done < <(find "$dir_path" -maxdepth 1 -type f | sort)
}

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --mode=*)
            MODE="${arg#--mode=}"
            ;;
        --pr-title=*)
            PR_TITLE="${arg#--pr-title=}"
            ;;
        --pr-body=*)
            PR_BODY="${arg#--pr-body=}"
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            usage
            ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "Error: --mode is required" >&2
    usage
fi

if [ "$MODE" != "pre-push" ] && [ "$MODE" != "ci" ]; then
    echo "Error: --mode must be 'pre-push' or 'ci'" >&2
    usage
fi

info "Workflow linter running in ${MODE} mode"

# Determine base ref for diff
# In GitHub Actions, GITHUB_BASE_REF is set to the PR target branch
if [ -n "${GITHUB_BASE_REF:-}" ]; then
    BASE_REF="origin/${GITHUB_BASE_REF}"
else
    BASE_REF="origin/main"
fi

if ! git rev-parse --verify --quiet "${BASE_REF}" >/dev/null; then
    emit_warning \
        "advisory" \
        "Base ref '${BASE_REF}' not found; skipping diff-based workflow checks" \
        "Shallow or partially fetched clones can omit the branch the linter compares against, which would otherwise look like 'no changes'. Fetch the base branch locally before rerunning workflow-lint."
    DIFF_CHECKS_AVAILABLE=false
else
    # Get changed files relative to base
    # --diff-filter=D lists deleted files, ADMR lists added/deleted/modified/renamed
    if ! CHANGED_FILES=$(git diff --name-only --diff-filter=ADMR "${BASE_REF}...HEAD" 2>/dev/null); then
        emit_warning \
            "advisory" \
            "Unable to compute changed files relative to '${BASE_REF}'; skipping diff-based workflow checks" \
            "The repository state prevented git diff from computing the expected comparison range, so the linter will keep running only non-diff checks."
        DIFF_CHECKS_AVAILABLE=false
    fi

    if ! DELETED_FILES=$(git diff --name-only --diff-filter=D "${BASE_REF}...HEAD" 2>/dev/null); then
        emit_warning \
            "advisory" \
            "Unable to compute deleted files relative to '${BASE_REF}'; skipping diff-based workflow checks" \
            "The repository state prevented git diff from computing the expected comparison range, so the linter will keep running only non-diff checks."
        DIFF_CHECKS_AVAILABLE=false
    fi

    if ! NAME_STATUS=$(git diff --name-status --find-renames "${BASE_REF}...HEAD" 2>/dev/null); then
        emit_warning \
            "advisory" \
            "Unable to compute file status changes relative to '${BASE_REF}'; skipping diff-based workflow checks" \
            "The repository state prevented git diff from computing rename-aware file status changes, so the linter will keep running only non-diff checks."
        DIFF_CHECKS_AVAILABLE=false
    fi

    if $DIFF_CHECKS_AVAILABLE && [ -z "$CHANGED_FILES" ] && [ -z "$DELETED_FILES" ]; then
        info "No changes detected relative to ${BASE_REF}"
    fi
fi

# =============================================================================
# Check 1: Issue lifecycle (pre-push + ci)
# Files removed from docs/issues/ must appear in docs/issues/done/
# =============================================================================
check_issue_lifecycle() {
    if ! $DIFF_CHECKS_AVAILABLE; then
        return
    fi

    local deleted_issues
    deleted_issues=$(echo "$DELETED_FILES" | grep '^docs/issues/[^/]*\.md$' || true)

    if [ -z "$deleted_issues" ]; then
        return
    fi

    for issue_file in $deleted_issues; do
        local base_name
        local done_file
        base_name=$(basename "$issue_file")
        done_file="docs/issues/done/$base_name"
        # Check if the file was added to done/ in this diff
        if ! echo "$CHANGED_FILES" | grep -qF "$done_file"; then
            emit_warning \
                "fixable" \
                "Issue file '${issue_file}' was deleted instead of moved to done/" \
                "Issues must be preserved for audit trail (AI_WORKFLOW.md Step 3)" \
                "git mv ${issue_file} docs/issues/done/${base_name}"
        fi
    done
}

# =============================================================================
# Check 2: Docs-change hint (ci only)
# If code files changed but no docs/ files changed, warn (unless [trivial])
# =============================================================================
check_docs_change_hint() {
    if ! $DIFF_CHECKS_AVAILABLE; then
        return
    fi

    if [ "$MODE" != "ci" ]; then
        return
    fi

    # Check for [trivial] marker in PR title or body
    if echo "$PR_TITLE" | grep -qi '\[trivial\]'; then
        return
    fi
    if echo "$PR_BODY" | grep -qi '\[trivial\]'; then
        return
    fi

    # Check if any code files changed (non-docs, non-config)
    local code_changed=false
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        case "$file" in
            docs/*|*.md|.gitignore|.githooks/*|*.yml|*.yaml)
                # Not code files
                ;;
            *)
                code_changed=true
                break
                ;;
        esac
    done <<< "$CHANGED_FILES"

    if ! $code_changed; then
        return
    fi

    # Check if any docs/ files changed
    local docs_changed=false
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        case "$file" in
            docs/*)
                docs_changed=true
                break
                ;;
        esac
    done <<< "$CHANGED_FILES"

    if ! $docs_changed; then
        emit_warning \
            "advisory" \
            "Code changed without updating docs/ (Spec-Code Parity review needed)" \
            "docs/specs/ should usually change with implementation updates (AI_WORKFLOW.md Core Principle 2)"
    fi
}

# =============================================================================
# Check 3: Branch naming convention (pre-push + ci)
# Branch must match <type>/<description> where type is plan|feat|fix|chore|docs
# =============================================================================
check_branch_naming() {
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)

    # Skip for main/master or detached HEAD
    if [ -z "$branch" ] || [ "$branch" = "main" ] || [ "$branch" = "master" ] || [ "$branch" = "HEAD" ]; then
        return
    fi

    local valid_types="plan|feat|fix|chore|docs"
    if ! echo "$branch" | grep -qE "^(${valid_types})/[a-z0-9]([a-z0-9-]*[a-z0-9])?$"; then
        emit_warning \
            "fixable" \
            "Invalid branch name: '${branch}'" \
            "Consistent naming enables automation and exec-plan mapping (AI_WORKFLOW.md Branch Naming Convention)" \
            "Create a compliant branch with ww create <type>/<description> where type = plan|feat|fix|chore|docs and description is kebab-case (for example: feat/add-auth)"
    fi
}

# =============================================================================
# Check 4: Exec-plan existence (pre-push + ci)
# feat/* and fix/* branches require a matching exec-plan file
# =============================================================================
check_exec_plan_existence() {
    local branch
    branch=$(current_branch)

    # Only check feat/* and fix/* branches
    if ! echo "$branch" | grep -qE "^(feat|fix)/"; then
        return
    fi

    local plan_name="${branch#*/}"
    local plan_paths
    local todo_file
    local done_file
    plan_paths=$(resolve_exec_plan_paths "$plan_name")
    todo_file="${plan_paths%%|*}"
    done_file="${plan_paths##*|}"

    if [ ! -f "$todo_file" ] && [ ! -f "$done_file" ]; then
        emit_warning \
            "fixable" \
            "Missing exec-plan for branch '${branch}'" \
            "feat/* and fix/* branches must have a plan before implementation (AI_WORKFLOW.md Exec-Plan Mapping)" \
            "Create the matching numbered plan first on plan/${plan_name}, then add docs/exec-plan/todo/<sequence>-${plan_name}.md"
    fi
}

# =============================================================================
# Check 5: Workflow docs should not reintroduce raw-git startup (pre-push + ci)
# Warn when migrated workflow-facing docs/skills contain startup snippets that
# bypass the global ww CLI.
# =============================================================================
check_workflow_doc_startup_commands() {
    if ! $DIFF_CHECKS_AVAILABLE; then
        return
    fi

    local workflow_files=(
        "AI_WORKFLOW.md"
        "AGENTS.md"
        "README.md"
        "skills/plan-execution/SKILL.md"
        "skills/execute-task/SKILL.md"
        "skills/triage-tasks/SKILL.md"
        "skills/plan-project/SKILL.md"
        "skills/review-task/SKILL.md"
        "skills/manage-workflow/SKILL.md"
    )
    # shellcheck disable=SC2016
    local raw_git_pattern='^[[:space:]]*git fetch origin([[:space:]]|$)|^[[:space:]]*git switch -c[[:space:]]|`git fetch origin`|`git switch -c [^`]+`|`git fetch origin && git switch -c [^`]+`'
    local file

    for file in "${workflow_files[@]}"; do
        if ! echo "$CHANGED_FILES" | grep -qxF "$file"; then
            continue
        fi

        if grep -nE "$raw_git_pattern" "$file" >/dev/null 2>&1; then
            emit_warning \
                "fixable" \
                "Workflow doc '${file}' reintroduces raw git startup commands" \
                "Normal planning/execution should dogfood the global ww CLI (docs/specs/ww-dogfooding-workflow.md)" \
                "Replace startup instructions with 'ww create ...' and 'cd \"\$(ww cd ...)\"'"
        fi
    done
}

# =============================================================================
# Check 6: Linked local issues declared in completed exec-plans must move to done/
# Narrow scope: only the matching feat/* or fix/* branch, only after the plan
# has moved to docs/exec-plan/done/, and only for explicit docs/issues/*.md
# paths named on an Addresses: line.
# =============================================================================
check_linked_issue_resolution() {
    if ! $DIFF_CHECKS_AVAILABLE; then
        return
    fi

    local plan_paths
    plan_paths=$(current_exec_plan_paths)
    [ -z "$plan_paths" ] && return

    local done_plan_file="${plan_paths##*|}"

    if [ ! -f "$done_plan_file" ]; then
        return
    fi

    local linked_issues
    linked_issues=$(extract_linked_issue_paths_from_plan "$done_plan_file")

    if [ -z "$linked_issues" ]; then
        return
    fi

    local issue_file
    for issue_file in $linked_issues; do
        local base_name
        local moved_issue_file
        local plan_reference
        base_name=$(basename "$issue_file")
        moved_issue_file="docs/issues/done/$base_name"
        plan_reference="${done_plan_file}"

        if diff_includes_rename "$issue_file" "$moved_issue_file"; then
            continue
        fi

        if pr_body_justifies_open_issue "$issue_file"; then
            continue
        fi

        emit_warning \
            "fixable" \
            "Completed exec-plan '${plan_reference}' links local issue '${issue_file}' but this branch does not move it to done/" \
            "Execution branches should close explicitly linked local issues in the same branch so reviewers and future sessions can trust the plan-to-issue completion trail (AI_WORKFLOW.md Step 3)." \
            "Move the issue with 'git mv ${issue_file} ${moved_issue_file}', or explain in the PR body why ${issue_file} remains open."
    done
}

# =============================================================================
# Check 7: Active plan / issue naming (pre-push + ci)
# Active files under docs/exec-plan/todo/ and docs/issues/ must use
# <sequence>-<name>.md, while README.md remains exempt.
# =============================================================================
check_active_workflow_file_naming() {
    check_active_filename_format "docs/exec-plan/todo" "exec-plan"
    check_active_filename_format "docs/issues" "issue"
}

# Run checks
check_issue_lifecycle
check_docs_change_hint
check_branch_naming
check_exec_plan_existence
check_workflow_doc_startup_commands
check_linked_issue_resolution
check_active_workflow_file_naming

# Summary
if [ "$WARN_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}Workflow linter summary:${NC}" >&2
    echo "  Total warnings: ${WARN_COUNT}" >&2
    echo "  Fixable: ${FIXABLE_WARN_COUNT}" >&2
    echo "  Advisory: ${ADVISORY_WARN_COUNT}" >&2
    if [ "$FIXABLE_WARN_COUNT" -gt 0 ]; then
        echo "  Reminder: resolve fixable warnings before push/PR unless a human instruction conflicts or the warning is a clear false positive." >&2
    fi
else
    info "Workflow linter: all checks passed"
fi

exit 0
