#!/bin/bash
set -euo pipefail

# Workflow linter for AI-Centered Development
# Mechanically enforces rules declared in AI_WORKFLOW.md
# All checks are warnings only (exit 0)

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

MODE=""
PR_TITLE=""
PR_BODY=""
WARN_COUNT=0

usage() {
    echo "Usage: $0 --mode=pre-push|ci [--pr-title=TITLE] [--pr-body=BODY]" >&2
    exit 1
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
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

# Get changed files relative to base
# --diff-filter=D lists deleted files, ADMR lists added/deleted/modified/renamed
CHANGED_FILES=$(git diff --name-only --diff-filter=ADMR "${BASE_REF}...HEAD" 2>/dev/null || true)
DELETED_FILES=$(git diff --name-only --diff-filter=D "${BASE_REF}...HEAD" 2>/dev/null || true)

if [ -z "$CHANGED_FILES" ] && [ -z "$DELETED_FILES" ]; then
    info "No changes detected relative to origin/main"
    exit 0
fi

# =============================================================================
# Check 1: Issue lifecycle (pre-push + ci)
# Files removed from docs/issues/ must appear in docs/issues/done/
# =============================================================================
check_issue_lifecycle() {
    local deleted_issues
    deleted_issues=$(echo "$DELETED_FILES" | grep '^docs/issues/[^/]*\.md$' || true)

    if [ -z "$deleted_issues" ]; then
        return
    fi

    for issue_file in $deleted_issues; do
        basename=$(basename "$issue_file")
        done_file="docs/issues/done/$basename"
        # Check if the file was added to done/ in this diff
        if ! echo "$CHANGED_FILES" | grep -qF "$done_file"; then
            warn "Issue file '${issue_file}' was deleted instead of moved to done/"
            warn "  WHY: Issues must be preserved for audit trail (AI_WORKFLOW.md Step 3)"
            warn "  FIX: git mv ${issue_file} docs/issues/done/${basename}"
        fi
    done
}

# =============================================================================
# Check 2: Docs-change hint (ci only)
# If code files changed but no docs/ files changed, warn (unless [trivial])
# =============================================================================
check_docs_change_hint() {
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
        warn "Code changed without updating docs/ (Spec-Code Parity violation)"
        warn "  WHY: docs/specs/ must match implementation (AI_WORKFLOW.md Core Principle 2)"
        warn "  FIX: Update the relevant file in docs/specs/ to reflect your code changes"
        warn "       OR add [trivial] to the PR title if no spec update is needed"
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
        warn "Invalid branch name: '${branch}'"
        warn "  WHY: Consistent naming enables automation and exec-plan mapping (AI_WORKFLOW.md Branch Naming Convention)"
        warn "  FIX: git switch -c <type>/<description> where:"
        warn "       type = plan | feat | fix | chore | docs"
        warn "       description = kebab-case (e.g., feat/add-auth, fix/login-bug)"
    fi
}

# =============================================================================
# Check 4: Exec-plan existence (pre-push + ci)
# feat/* and fix/* branches require a matching exec-plan file
# =============================================================================
check_exec_plan_existence() {
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)

    # Only check feat/* and fix/* branches
    if ! echo "$branch" | grep -qE "^(feat|fix)/"; then
        return
    fi

    local plan_name="${branch#*/}"
    local todo_file="docs/exec-plan/todo/${plan_name}.md"
    local done_file="docs/exec-plan/done/${plan_name}.md"

    if [ ! -f "$todo_file" ] && [ ! -f "$done_file" ]; then
        warn "Missing exec-plan for branch '${branch}'"
        warn "  WHY: feat/* and fix/* branches must have a plan before implementation (AI_WORKFLOW.md Exec-Plan Mapping)"
        warn "  FIX: Create the plan file first on a plan/ branch:"
        warn "       git switch -c plan/${plan_name} origin/main"
        warn "       # then create: docs/exec-plan/todo/${plan_name}.md"
    fi
}

# Run checks
check_issue_lifecycle
check_docs_change_hint
check_branch_naming
check_exec_plan_existence

# Summary
if [ "$WARN_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}Workflow linter: ${WARN_COUNT} warning(s)${NC}" >&2
else
    info "Workflow linter: all checks passed"
fi

exit 0
