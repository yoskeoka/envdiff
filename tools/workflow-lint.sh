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
REPORT_FILE=""
WARN_COUNT=0
FIXABLE_WARN_COUNT=0
ADVISORY_WARN_COUNT=0
DIFF_CHECKS_AVAILABLE=true
CHANGED_FILES=""
DELETED_FILES=""
DIFF_BASE=""

usage() {
    echo "Usage: $0 --mode=pre-push|ci [--pr-title=TITLE] [--pr-body=BODY] [--report-file=PATH]" >&2
    exit 1
}

json_escape() {
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

append_report_record() {
    local json_record="$1"

    if [ -z "$REPORT_FILE" ]; then
        return
    fi

    printf '%s\n' "$json_record" >> "$REPORT_FILE"
}

emit_warning() {
    local warning_class="$1"
    local finding="$2"
    local why="$3"
    local fix="${4:-}"
    local normalized_class="$warning_class"
    local json_fix='null'

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

    if [ -n "$REPORT_FILE" ]; then
        if [ -n "$fix" ]; then
            json_fix=$(json_escape "$fix")
        fi

        append_report_record "$(printf '{"type":"warning","class":%s,"finding":%s,"why":%s,"fix":%s}' \
            "$(json_escape "$normalized_class")" \
            "$(json_escape "$finding")" \
            "$(json_escape "$why")" \
            "$json_fix")"
    fi
}

info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

active_workflow_filename_regex() {
    echo '^((000[1-9])|(00[1-9][0-9])|(0[1-9][0-9]{2})|([1-9][0-9]{3,}))-[a-z0-9]([a-z0-9-]*[a-z0-9])?\.md$'
}

matching_exec_plan_files() {
    local plan_name="$1"

    [ -d docs/exec-plan/todo ] || return 0

    find docs/exec-plan/todo -maxdepth 1 -type f \
        \( -name "*-${plan_name}.md" -o -name "${plan_name}.md" \) \
        | sort
}

deleted_matching_exec_plan_files() {
    local plan_name="$1"

    printf '%s\n' "$DELETED_FILES" | awk -v plan_name="$plan_name" '
        $0 ~ "^docs/exec-plan/todo/" &&
            ($0 ~ ("-" plan_name "\\.md$") || $0 ~ ("/" plan_name "\\.md$")) {
            print
        }
    ' | sort
}

current_github_repo_slug() {
    local origin_url
    origin_url=$(git remote get-url origin 2>/dev/null || true)

    case "$origin_url" in
        git@github.com:*.git)
            origin_url="${origin_url#git@github.com:}"
            origin_url="${origin_url%.git}"
            printf '%s\n' "$origin_url"
            ;;
        git@github.com:*)
            origin_url="${origin_url#git@github.com:}"
            printf '%s\n' "$origin_url"
            ;;
        https://github.com/*.git)
            origin_url="${origin_url#https://github.com/}"
            origin_url="${origin_url%.git}"
            printf '%s\n' "$origin_url"
            ;;
        https://github.com/*)
            origin_url="${origin_url#https://github.com/}"
            printf '%s\n' "$origin_url"
            ;;
    esac
}

deleted_exec_plan_content() {
    local plan_file="$1"

    git show "${DIFF_BASE}:${plan_file}" 2>/dev/null || true
}

extract_linked_issue_paths_from_deleted_plan() {
    local plan_file="$1"

    deleted_exec_plan_content "$plan_file" | awk '
        function emit_paths(text) {
            gsub(/`/, "", text)
            while (match(text, /docs\/issues\/[A-Za-z0-9._-]+\.md/)) {
                print substr(text, RSTART, RLENGTH)
                text = substr(text, RSTART + RLENGTH)
            }
        }

        /^Addresses:/ {
            emit_paths($0)
            collect = 1
            next
        }

        collect && /^#{1,6}[[:space:]]/ { collect = 0 }
        collect && /^[^[:space:]#-].*:[[:space:]]*$/ { collect = 0 }
        collect { emit_paths($0) }
    '
}

extract_linked_github_issue_urls_from_deleted_plan() {
    local plan_file="$1"

    deleted_exec_plan_content "$plan_file" | awk '
        function is_addresses_continuation(line) {
            return line ~ /^[[:space:]]*([-*][[:space:]]+)?https:\/\/github\.com\// \
                || line ~ /^[[:space:]]*([-*][[:space:]]+)?`https:\/\/github\.com\//
        }

        function emit_urls(text) {
            gsub(/`/, "", text)
            while (match(text, /https:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\/issues\/[0-9]+/)) {
                print substr(text, RSTART, RLENGTH)
                text = substr(text, RSTART + RLENGTH)
            }
        }

        /^Addresses:/ { emit_urls($0); collect = 1; next }
        collect && /^#{1,6}[[:space:]]/ { collect = 0 }
        collect && /^$/ { collect = 0 }
        collect && !is_addresses_continuation($0) { collect = 0 }
        collect { emit_urls($0) }
    '
}

check_ambiguous_exec_plan_mapping() {
    local branch="$1"
    local plan_name="$2"
    local active_matches=0
    local deleted_matches=0
    local path=""

    while IFS= read -r path; do
        [ -z "$path" ] && continue
        active_matches=$((active_matches + 1))
    done < <(matching_exec_plan_files "$plan_name")

    while IFS= read -r path; do
        [ -z "$path" ] && continue
        deleted_matches=$((deleted_matches + 1))
    done < <(deleted_matching_exec_plan_files "$plan_name")

    if [ "$active_matches" -gt 1 ] || [ "$deleted_matches" -gt 1 ]; then
        emit_warning \
            "fixable" \
            "Ambiguous exec-plan mapping for branch '${branch}'" \
            "Multiple active or deleted exec-plans share the same '-${plan_name}.md' suffix, so workflow-lint cannot reliably tell which file the branch should map to." \
            "Keep only one active plan or one deleted completion plan for suffix '${plan_name}.md'."
    fi
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

pr_body_closes_github_issue() {
    local issue_url="$1"
    local same_repo_ref="$2"

    if [ "$MODE" != "ci" ] || [ -z "$PR_BODY" ]; then
        return 1
    fi

    printf '%s\n' "$PR_BODY" | awk -v issue_url="$issue_url" -v same_repo_ref="$same_repo_ref" '
        function regex_escape(text,    escaped) {
            escaped = text
            gsub(/[][(){}.^$*+?|\\-]/, "\\\\&", escaped)
            return escaped
        }

        function line_closes_issue(line, escaped_issue_url, escaped_same_repo_ref, pattern) {
            if (line !~ /(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved):?[[:space:]]*/) {
                return 0
            }

            pattern = escaped_issue_url "([^0-9]|$)"
            if (line ~ pattern) {
                return 1
            }

            if (escaped_same_repo_ref != "") {
                pattern = escaped_same_repo_ref "([^0-9]|$)"
                if (line ~ pattern) {
                    return 1
                }
            }

            return 0
        }

        BEGIN {
            IGNORECASE = 1
            escaped_issue_url = regex_escape(issue_url)
            escaped_same_repo_ref = regex_escape(same_repo_ref)
        }

        {
            if (line_closes_issue($0, escaped_issue_url, escaped_same_repo_ref)) {
                found = 1
            }
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
        --report-file=*)
            REPORT_FILE="${arg#--report-file=}"
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

if [ -n "$REPORT_FILE" ]; then
    mkdir -p "$(dirname "$REPORT_FILE")"
    : > "$REPORT_FILE"
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
    if ! DIFF_BASE=$(git merge-base "$BASE_REF" HEAD 2>/dev/null); then
        emit_warning \
            "advisory" \
            "Unable to resolve a merge base with '${BASE_REF}'; skipping diff-based workflow checks" \
            "The repository state prevented workflow-lint from recovering the base-side completion artifacts."
        DIFF_CHECKS_AVAILABLE=false
    fi

    # Get changed files relative to base
    # --diff-filter=D lists deleted files, ADMR lists added/deleted/modified/renamed
    if $DIFF_CHECKS_AVAILABLE && ! CHANGED_FILES=$(git diff --name-only --diff-filter=ADMR "${DIFF_BASE}...HEAD" 2>/dev/null); then
        emit_warning \
            "advisory" \
            "Unable to compute changed files relative to '${BASE_REF}'; skipping diff-based workflow checks" \
            "The repository state prevented git diff from computing the expected comparison range, so the linter will keep running only non-diff checks."
        DIFF_CHECKS_AVAILABLE=false
    fi

    if $DIFF_CHECKS_AVAILABLE && ! DELETED_FILES=$(git diff --name-only --diff-filter=D "${DIFF_BASE}...HEAD" 2>/dev/null); then
        emit_warning \
            "advisory" \
            "Unable to compute deleted files relative to '${BASE_REF}'; skipping diff-based workflow checks" \
            "The repository state prevented git diff from computing the expected comparison range, so the linter will keep running only non-diff checks."
        DIFF_CHECKS_AVAILABLE=false
    fi

    if $DIFF_CHECKS_AVAILABLE && [ -z "$CHANGED_FILES" ] && [ -z "$DELETED_FILES" ]; then
        info "No changes detected relative to ${BASE_REF}"
    fi
fi

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
# feat/* and fix/* branches require a matching active exec-plan file, unless
# this branch is closing it by deleting the matching plan in the branch diff.
# =============================================================================
check_exec_plan_existence() {
    local branch
    branch=$(current_branch)

    # Only check feat/* and fix/* branches
    if ! echo "$branch" | grep -qE "^(feat|fix)/"; then
        return
    fi

    local plan_name="${branch#*/}"
    check_ambiguous_exec_plan_mapping "$branch" "$plan_name"
    local active_plan
    local deleted_plan
    active_plan=$(matching_exec_plan_files "$plan_name" | head -n 1)
    deleted_plan=$(deleted_matching_exec_plan_files "$plan_name" | head -n 1)

    if [ -z "$active_plan" ] && [ -z "$deleted_plan" ]; then
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
# Check 6: A deleted matching exec-plan requires deletion of its explicitly
# linked local issues, unless the PR body explains that an issue remains open.
# =============================================================================
check_linked_issue_resolution() {
    if ! $DIFF_CHECKS_AVAILABLE; then
        return
    fi

    local branch
    branch=$(current_branch)
    if ! echo "$branch" | grep -qE "^(feat|fix)/"; then return; fi
    local plan_name="${branch#*/}"
    local deleted_plan_file
    deleted_plan_file=$(deleted_matching_exec_plan_files "$plan_name" | head -n 1)
    [ -z "$deleted_plan_file" ] && return

    local linked_issues
    linked_issues=$(extract_linked_issue_paths_from_deleted_plan "$deleted_plan_file")

    if [ -z "$linked_issues" ]; then
        return
    fi

    local issue_file
    for issue_file in $linked_issues; do
        if printf '%s\n' "$DELETED_FILES" | grep -qxF "$issue_file"; then
            continue
        fi

        if pr_body_justifies_open_issue "$issue_file"; then
            continue
        fi

        emit_warning \
            "fixable" \
            "Deleted exec-plan '${deleted_plan_file}' links local issue '${issue_file}' but this branch does not delete it" \
            "Execution branches should remove explicitly linked resolved local issues in the same diff so the PR and Git history remain the completion trail (AI_WORKFLOW.md Execution)." \
            "Delete '${issue_file}' in this branch, or explain in the PR body why it remains open."
    done
}

# =============================================================================
# Check 6a: Linked external GitHub issues declared in deleted exec-plans
# must appear in PR-body closing keywords unless intentionally left open.
# Narrow scope: only the matching feat/* or fix/* branch after the plan is
# deleted, only for explicit GitHub issue URLs named
# on an Addresses: line, and only in CI mode where PR body input exists.
# =============================================================================
check_linked_github_issue_closure() {
    if [ "$MODE" != "ci" ]; then
        return
    fi

    if ! $DIFF_CHECKS_AVAILABLE; then return; fi
    local branch
    branch=$(current_branch)
    if ! echo "$branch" | grep -qE "^(feat|fix)/"; then return; fi
    local plan_name="${branch#*/}"
    local deleted_plan_file
    deleted_plan_file=$(deleted_matching_exec_plan_files "$plan_name" | head -n 1)
    [ -z "$deleted_plan_file" ] && return

    local linked_issue_urls
    linked_issue_urls=$(extract_linked_github_issue_urls_from_deleted_plan "$deleted_plan_file")

    if [ -z "$linked_issue_urls" ]; then
        return
    fi

    local repo_slug
    repo_slug=$(current_github_repo_slug)

    local issue_url
    while IFS= read -r issue_url; do
        [ -z "$issue_url" ] && continue

        if pr_body_justifies_open_issue "$issue_url"; then
            continue
        fi

        local same_repo_ref=""
        if [ -n "$repo_slug" ] && echo "$issue_url" | grep -q "^https://github.com/${repo_slug}/issues/[0-9]\+$"; then
            same_repo_ref="#${issue_url##*/}"
        fi

        if pr_body_closes_github_issue "$issue_url" "$same_repo_ref"; then
            continue
        fi

        emit_warning \
            "fixable" \
            "Deleted exec-plan '${deleted_plan_file}' links external GitHub issue '${issue_url}' but the PR body does not include a matching closing keyword" \
            "Execution PRs should close explicitly linked external GitHub issues so repo-native feedback is resolved together with the implementation record (AI_WORKFLOW.md Step 3)." \
            "Add 'Closes ${same_repo_ref:-$issue_url}' to the PR body, or explain there why ${issue_url} remains open."
    done <<< "$linked_issue_urls"
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

# =============================================================================
# Check 8: Workspace workflow context contract (pre-push + ci)
# The workspace owns this layered documentation contract. Child repositories may
# consume workflow skills without carrying every workspace document, so scope
# this check to the workspace repository itself.
# =============================================================================
check_workflow_context_contract() {
    local origin_url
    origin_url=$(git remote get-url origin 2>/dev/null || true)
    case "$origin_url" in
        *yoskeoka/vibe-coding-workspace*) ;;
        *) return ;;
    esac

    local required_file
    local required_files=(
        "AGENTS.md"
        "AI_WORKFLOW.md"
        "docs/specs/workflow-context-contract.md"
        "docs/design-decisions/README.md"
        "docs/lessons.md"
    )
    for required_file in "${required_files[@]}"; do
        if [ ! -f "$required_file" ]; then
            emit_warning \
                "fixable" \
                "Workflow context contract is missing '${required_file}'" \
                "The workspace requires a universal entrypoint, lifecycle reference, on-demand contract, ADR index, and active-exceptions register." \
                "Restore '${required_file}' from the workflow context contract."
        fi
    done

    if [ -f "docs/design-decisions/adr.md" ]; then
        emit_warning \
            "fixable" \
            "Monolithic ADR file 'docs/design-decisions/adr.md' remains" \
            "Architecture decisions are immutable numbered records indexed from docs/design-decisions/README.md." \
            "Migrate the record to docs/design-decisions/adr/ and remove adr.md."
    fi

    if [ -f "AGENTS.md" ] && ! grep -q 'AI_WORKFLOW.md#' "AGENTS.md"; then
        emit_warning "fixable" "AGENTS.md does not route tasks to lifecycle sections" \
            "The short universal entrypoint must direct agents to phase-specific reads." \
            "Add the task-to-document table with AI_WORKFLOW.md section links."
    fi
    if [ -f "AI_WORKFLOW.md" ] && ! grep -q 'workflow-context-contract.md' "AI_WORKFLOW.md"; then
        emit_warning "fixable" "AI_WORKFLOW.md does not link the workflow context contract" \
            "Lifecycle rules and document ownership must remain discoverable together." \
            "Link docs/specs/workflow-context-contract.md from AI_WORKFLOW.md."
    fi

    local skill_file
    local workflow_skills=(
        "skills/plan-execution/SKILL.md"
        "skills/execute-task/SKILL.md"
        "skills/review-task/SKILL.md"
        "skills/post-task-review/SKILL.md"
        "skills/manage-workflow/SKILL.md"
        "skills/plan-project/SKILL.md"
        "skills/triage-tasks/SKILL.md"
    )
    for skill_file in "${workflow_skills[@]}"; do
        if [ ! -f "$skill_file" ] || ! grep -q 'AI_WORKFLOW.md#' "$skill_file"; then
            emit_warning "fixable" "Workflow skill '${skill_file}' lacks a lifecycle link" \
                "Skills own procedures and route shared lifecycle rules to AI_WORKFLOW.md." \
                "Add the applicable AI_WORKFLOW.md section link."
        fi
    done

    if [ -d "docs/design-decisions/adr" ]; then
        local adr_file
        local adr_base
        local adr_count=0
        for adr_file in docs/design-decisions/adr/*.md; do
            [ -e "$adr_file" ] || continue
            adr_count=$((adr_count + 1))
            adr_base=$(basename "$adr_file")
            if ! grep -qE "^\| \[[0-9]{4}\]\(adr/${adr_base//./\\.}\) \| (Proposed|Accepted|Deprecated|Superseded) \| [^|]+ \| [^|]+ \|$" "docs/design-decisions/README.md"; then
                emit_warning "fixable" "ADR '${adr_file}' is not indexed" \
                    "Every immutable decision record needs an ID, status, tags, and one-line outcome in the ADR index." \
                    "Add an ID, status, tags, and outcome row to docs/design-decisions/README.md."
            fi
            if ! grep -qE '^# .+' "$adr_file" \
                || ! grep -q '^## Status$' "$adr_file" \
                || ! grep -q '^## Context$' "$adr_file" \
                || ! grep -q '^## Decision$' "$adr_file" \
                || ! grep -q '^## Consequences$' "$adr_file"; then
                emit_warning "fixable" "ADR '${adr_file}' is not a Michael Nygard record" \
                    "ADR records require title, Status, Context, Decision, and Consequences sections." \
                    "Use the ADR template under skills/manage-workflow/templates/docs/design-decisions/adr/."
            fi
        done
        if [ "$adr_count" -eq 0 ]; then
            emit_warning "fixable" "ADR directory has no numbered decision records" \
                "The compact ADR layout keeps decisions as immutable per-record files." \
                "Add a migrated or newly accepted record under docs/design-decisions/adr/."
        fi
    else
        emit_warning "fixable" "ADR record directory is missing" \
            "The workspace ADR index requires docs/design-decisions/adr/." \
            "Create docs/design-decisions/adr/ and migrate decisions into numbered records."
    fi

    if [ -f "docs/design-decisions/README.md" ] \
        && ! grep -qE '^\| \[?[0-9]{4}\]?\(?(adr/|.*adr/)' "docs/design-decisions/README.md"; then
        emit_warning "fixable" "ADR index has no numbered record rows" \
            "The ADR index must expose ID, status, tags, and one-line outcome for each decision." \
            "Add linked numbered ADR rows to docs/design-decisions/README.md."
    fi

    if [ -f "docs/lessons.md" ]; then
        local lesson_count
        lesson_count=$(grep -c '^## ' "docs/lessons.md" || true)
        if [ "$lesson_count" -gt 10 ]; then
            emit_warning "fixable" "Active exceptions register has ${lesson_count} entries" \
                "docs/lessons.md is capped at ten unresolved recurring risks." \
                "Promote resolved rules to canonical docs and remove their exception entries."
        fi
        local malformed_exceptions
        malformed_exceptions=$(awk '
            /^## / {
                if (active && (!remediation || !trigger)) bad++
                active = 1
                remediation = 0
                trigger = 0
                next
            }
            /^Canonical remediation:/ { remediation = 1 }
            /^Review trigger:/ { trigger = 1 }
            END {
                if (active && (!remediation || !trigger)) bad++
                print bad + 0
            }
        ' "docs/lessons.md")
        if [ "$malformed_exceptions" -gt 0 ]; then
            emit_warning "fixable" "${malformed_exceptions} active exception entries lack required metadata" \
                "Each unresolved recurring risk must include canonical remediation and a review trigger." \
                "Add 'Canonical remediation: <link>' and 'Review trigger: <condition>' to every active exception."
        fi
    fi
}

# Run checks
check_docs_change_hint
check_branch_naming
check_exec_plan_existence
check_workflow_doc_startup_commands
check_linked_issue_resolution
check_linked_github_issue_closure
check_active_workflow_file_naming
check_workflow_context_contract

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

append_report_record "$(printf '{"type":"summary","total":%s,"fixable":%s,"advisory":%s}' \
    "$WARN_COUNT" \
    "$FIXABLE_WARN_COUNT" \
    "$ADVISORY_WARN_COUNT")"

exit 0
