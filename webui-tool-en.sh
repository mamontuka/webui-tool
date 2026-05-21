#!/bin/bash
#===============================================================================
# 🦌 webui-tool.sh — Universal Multitool for Open WebUI
#===============================================================================
# Combines functions for building, deploying, checking changes, and resolving conflicts.
#
# Usage:
#   ./webui-tool.sh deploy [main|dev] [pr:<num>] [--build-only] [--no-upstream]
#       Build and deploy (or build only with --build-only)
#       Option --no-upstream: deploy current custom branch WITHOUT updating from upstream
#
#   ./webui-tool.sh check [main|dev]
#       Check repository status, compare with upstream
#
#   ./webui-tool.sh accept-upstream
#       Accept all changes from upstream, overwriting local conflicts
#
#   ./webui-tool.sh help
#       Show help
#
# Requirements: Git, Python 3, curl, Node.js (installed automatically)
#===============================================================================
set -e
#-------------------------------------------------------------------------------
# 🔧 CONFIGURATION
#-------------------------------------------------------------------------------
REPO_URL="https://github.com/open-webui/open-webui.git"
WEBUI_DIR="$HOME/ai/dev/webui"
CUSTOM_BRANCH="custom"
NVM_VERSION="v0.40.1"
export NVM_DIR="$HOME/.nvm"
SOURCE_BACKEND_DIR="$WEBUI_DIR/backend/open_webui"
SOURCE_FRONTEND_DIR="$WEBUI_DIR/build"
TARGET_DIR="/root/ai/core/servers/webui"
SERVICE_NAME="ai-core-webui"
# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
#-------------------------------------------------------------------------------
# 🛠️ HELPER FUNCTIONS
#-------------------------------------------------------------------------------
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }
log_cmd()  { echo -e "${CYAN}[CMD]${NC} $1"; }
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Root privileges required."
        log_info "Run: sudo $0 $*"
        exit 1
    fi
}
ensure_webui_dir() {
    if [ ! -d "$WEBUI_DIR" ]; then
        log_err "Directory $WEBUI_DIR not found."
        log_info "First run: $0 deploy"
        exit 1
    fi
}
install_node() {
    if [ ! -d "$NVM_DIR" ]; then
        log_info "Installing NVM..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash
        source "$NVM_DIR/nvm.sh"
    else
        source "$NVM_DIR/nvm.sh"
    fi
    if [ -z "$(nvm current 2>/dev/null | grep '^v22')" ]; then
        log_info "Installing Node.js 22..."
        nvm install 22
        nvm alias default 22
    fi
    nvm use 22 > /dev/null 2>&1
}
#-------------------------------------------------------------------------------
# 📦 DEPLOY: Build and Deploy
#-------------------------------------------------------------------------------
cmd_deploy() {
    local target_branch="main"
    local pr_number=""
    local build_only=false
    local no_upstream=false
    for arg in "$@"; do
        case "$arg" in
            --build-only) build_only=true ;;
            --no-upstream) no_upstream=true ;;
            pr:[0-9]*) pr_number="${arg#pr:}" ;;
            dev|main) target_branch="$arg" ;;
            *) log_err "Unknown argument: $arg"; show_help; exit 1 ;;
        esac
    done
    # Validate combinations
    if [ "$no_upstream" = true ] && [ -n "$pr_number" ]; then
        log_err "Cannot use --no-upstream with PR!"
        log_info "PR requires upstream update to apply patch."
        exit 1
    fi
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}🚀 DEPLOY: Build and Install${NC}"
    echo -e "${YELLOW}========================================${NC}"
    local mode_desc="Mode: $target_branch"
    [ -n "$pr_number" ] && mode_desc="$mode_desc + PR #$pr_number"
    [ "$build_only" = true ] && mode_desc="$mode_desc (build only)"
    [ "$no_upstream" = true ] && mode_desc="Mode: CUSTOM ONLY (--no-upstream)"
    log_info "$mode_desc"
    # Repository preparation
    if [ "$no_upstream" = true ]; then
        setup_repo_no_upstream
    else
        setup_repo "$target_branch" "$pr_number"
    fi
    # Build
    build_backend
    build_frontend
    # Deploy
    if [ "$build_only" = true ]; then
        log_ok "Build completed. Deploy skipped (--build-only)."
        log_info "To deploy: sudo $0 deploy $target_branch ${pr_number:+pr:$pr_number}"
    else
        update_prod
    fi
    echo ""
    log_ok "🎉 All operations completed successfully!"
}
setup_repo_no_upstream() {
    ensure_webui_dir
    cd "$WEBUI_DIR"
    log_info "Working with current custom branch without upstream update..."
    local current_branch=$(git branch --show-current)
    if [ "$current_branch" != "$CUSTOM_BRANCH" ]; then
        log_info "Switching to $CUSTOM_BRANCH..."
        git checkout "$CUSTOM_BRANCH"
    fi
    if [ -n "$(git status --porcelain)" ]; then
        log_warn "Uncommitted changes detected in working directory!"
        log_info "Changes will be used as-is. Recommended to commit before deploy."
        echo ""
        git status --short | sed 's/^/   /'
        echo ""
    else
        log_ok "Working directory is clean."
    fi
    local last_commit=$(git log -1 --oneline)
    log_info "Current commit: $last_commit"
    log_ok "Ready. Will build current state of $CUSTOM_BRANCH."
}
setup_repo() {
    local target_branch="$1"
    local pr_number="$2"
    if [ ! -d "$WEBUI_DIR" ]; then
        log_info "Cloning repository..."
        mkdir -p "$(dirname "$WEBUI_DIR")"
        git clone "$REPO_URL" "$WEBUI_DIR"
        cd "$WEBUI_DIR"
        git checkout -b "$CUSTOM_BRANCH"
        log_ok "Repository cloned, branch $CUSTOM_BRANCH created."
        return
    fi
    cd "$WEBUI_DIR"
    if ! git remote | grep -q "upstream"; then
        git remote add upstream "$REPO_URL"
    fi
    git fetch upstream
    if ! git show-ref --verify --quiet refs/heads/$CUSTOM_BRANCH; then
        log_err "Branch $CUSTOM_BRANCH does not exist!"
        exit 1
    fi
    local current_branch=$(git branch --show-current)
    local stashed=false
    log_info "Updating branch $target_branch..."
    if [ "$current_branch" = "$target_branch" ]; then
        git reset --hard "upstream/$target_branch"
    elif [ "$current_branch" = "$CUSTOM_BRANCH" ]; then
        if [ -n "$(git status --porcelain)" ]; then
            log_warn "Uncommitted changes detected, stashing..."
            git stash push -m "Auto-stash before update"
            stashed=true
        fi
        git checkout -B "$target_branch" "upstream/$target_branch"
    else
        git checkout -B "$target_branch" "upstream/$target_branch"
    fi
    if [ -n "$pr_number" ]; then
        apply_pr "$pr_number" "$target_branch"
    fi
    log_info "Merging into $CUSTOM_BRANCH..."
    git checkout "$CUSTOM_BRANCH"
    if [ "$stashed" = true ]; then
        git stash pop || {
            log_err "Conflict during stash restore!"
            exit 1
        }
    fi
    if git merge "$target_branch" --no-commit --no-ff; then
        if [ -n "$(git status --porcelain)" ]; then
            local msg="Merge upstream/$target_branch"
            [ -n "$pr_number" ] && msg="$msg + PR #$pr_number"
            git commit -m "$msg into custom"
        fi
        log_ok "Merge successful."
    else
        log_err "Merge conflict! Resolve manually."
        exit 1
    fi
}
apply_pr() {
    local pr_num="$1"
    local base_branch="$2"
    log_info "Applying Pull Request #$pr_num..."
    local temp_branch="temp-pr-$pr_num"
    git checkout -B "$temp_branch" "$base_branch"
    local patch_url="https://github.com/open-webui/open-webui/pull/${pr_num}.patch"
    log_info "Downloading patch: $patch_url"
    if curl -sSL "$patch_url" | git am -3; then
        log_ok "PR #$pr_num applied successfully."
    else
        log_err "Failed to apply PR #$pr_num!"
        echo "Resolve conflicts manually:"
        echo "  1. git status"
        echo "  2. Edit files"
        echo "  3. git add <files>"
        echo "  4. git am --continue"
        echo "  5. git checkout $CUSTOM_BRANCH && git merge $temp_branch"
        exit 1
    fi
    git checkout "$base_branch"
    git merge "$temp_branch" --no-ff -m "Merge PR #$pr_num into $base_branch"
    git branch -D "$temp_branch"
}
build_backend() {
    log_info "Building Backend (Python venv)..."
    cd "$WEBUI_DIR"
    if [ ! -d "venv" ]; then
        log_info "Creating virtual environment..."
        python3 -m venv venv
    fi
    source venv/bin/activate
    pip install --upgrade pip -q
    pip install -r backend/requirements.txt -q
    deactivate
    log_ok "Backend ready."
}
build_frontend() {
    log_info "Building Frontend..."
    cd "$WEBUI_DIR"
    if [ ! -d "src" ]; then
        log_warn "src folder not found. Skipping frontend build."
        return 0
    fi
    install_node
    cd src
    npm install --silent
    npm run build
    cd ..
    if [ ! -d "build" ]; then
        log_err "Frontend build did not create build folder!"
        exit 1
    fi
    log_ok "Frontend ready (build/)."
}
update_prod() {
    log_info "=== 🚀 DEPLOY TO PRODUCTION ==="
    check_root
    if [[ ! -d "$SOURCE_BACKEND_DIR" ]]; then
        log_err "Backend not found: $SOURCE_BACKEND_DIR"
        exit 1
    fi
    if [[ ! -d "$SOURCE_FRONTEND_DIR" ]]; then
        log_err "Frontend build not found: $SOURCE_FRONTEND_DIR"
        exit 1
    fi
    if [[ ! -d "$TARGET_DIR" ]]; then
        log_err "Target dir not found: $TARGET_DIR"
        exit 1
    fi
    log_info "[1/5] Stopping service $SERVICE_NAME..."
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME"
        log_ok "Service stopped."
    else
        log_warn "Service already stopped."
    fi
    log_info "[2/5] Cleaning target directory..."
    cd "$TARGET_DIR"
    for item in *; do
        if [[ "$item" != "data" && "$item" != "frontend" && "$item" != "CHANGELOG.md" ]]; then
            if [[ -e "$item" ]]; then
                echo "  Removing: $item"
                rm -rf "$item"
            fi
        else
            echo "  Preserving: $item"
        fi
    done
    log_info "[3/5] Updating frontend..."
    local frontend_target="$TARGET_DIR/frontend"
    if [[ -d "$frontend_target" ]]; then
        rm -rf "$frontend_target"/*
        rm -rf "$frontend_target"/.[!.]* 2>/dev/null || true
    else
        mkdir -p "$frontend_target"
    fi
    cp -rf "$SOURCE_FRONTEND_DIR"/* "$frontend_target/"
    cp -rf "$SOURCE_FRONTEND_DIR"/.[!.]* "$frontend_target/" 2>/dev/null || true
    log_ok "Frontend updated."
    log_info "[4/5] Copying backend..."
    cd "$SOURCE_BACKEND_DIR"
    for item in *; do
        if [[ "$item" != "data" ]]; then
            if [[ -e "$item" ]]; then
                cp -rf "$item" "$TARGET_DIR/"
            fi
        fi
    done
    log_ok "Backend updated."
    log_info "[5/5] Starting service $SERVICE_NAME..."
    systemctl start "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_ok "Service started."
    else
        log_err "Service failed to start! Check: systemctl status $SERVICE_NAME"
        exit 1
    fi
    log_ok "=== DEPLOY COMPLETED SUCCESSFULLY ==="
}
#-------------------------------------------------------------------------------
# 🔍 CHECK: Verify Changes
#-------------------------------------------------------------------------------
cmd_check() {
    local target_branch="${1:-main}"
    ensure_webui_dir
    cd "$WEBUI_DIR"
    if [[ "$target_branch" != "main" && "$target_branch" != "dev" ]]; then
        log_err "Invalid branch '$target_branch'. Allowed: main or dev."
        exit 1
    fi
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}🔍 CHECK: Status Verification${NC}"
    echo -e "${YELLOW}========================================${NC}"
    log_info "Updating remote information..."
    git fetch upstream --quiet 2>/dev/null || git fetch upstream
    echo ""
    echo "📊 REPOSITORY STATUS REPORT"
    echo "==========================="
    echo ""
    echo "📍 Current branch:"
    local current=$(git branch --show-current)
    if [ "$current" = "$CUSTOM_BRANCH" ]; then
        echo "   ✅ $current (active)"
    else
        echo "   ⚠️ $current (expected $CUSTOM_BRANCH)"
    fi
    echo ""
    echo "📜 Recent commits in $CUSTOM_BRANCH:"
    git log --oneline -30 "$CUSTOM_BRANCH" | sed 's/^/   /'
    echo ""
    echo "🔄 Merge status with upstream/$target_branch:"
    local merge_base=$(git merge-base "$CUSTOM_BRANCH" "upstream/$target_branch")
    local upstream_head=$(git rev-parse "upstream/$target_branch")
    if [ "$merge_base" = "$upstream_head" ]; then
        echo "   ✅ Custom branch contains all changes from upstream/$target_branch"
    else
        echo "   ⚠️ New commits available in upstream/$target_branch."
        local commits_behind=$(git rev-list --count "$CUSTOM_BRANCH..upstream/$target_branch")
        echo "   📦 Updates available: $commits_behind commit(s)"
    fi
    echo ""
    echo "🔀 Differences between $CUSTOM_BRANCH and upstream/$target_branch:"
    local diff_stat=$(git diff --stat "upstream/$target_branch..$CUSTOM_BRANCH" 2>/dev/null || true)
    if [ -z "$diff_stat" ]; then
        echo "   ℹ️ No differences. Code identical to upstream/$target_branch."
    else
        echo "   Custom changes detected:"
        echo "$diff_stat" | sed 's/^/   /'
    fi
    echo ""
    echo "📝 Modified files:"
    local diff_files=$(git diff --name-only "upstream/$target_branch..$CUSTOM_BRANCH" 2>/dev/null || true)
    if [ -z "$diff_files" ]; then
        echo "   (no modified files)"
    else
        echo "$diff_files" | sed 's/^/   • /'
    fi
    echo ""
    echo "🔧 Uncommitted changes:"
    local status=$(git status --porcelain 2>/dev/null || true)
    if [ -z "$status" ]; then
        echo "   ✅ Working directory clean."
    else
        echo "   Changes detected:"
        echo "$status" | sed 's/^/   /'
    fi
    echo ""
    log_ok "Check completed!"
    echo ""
    echo "💡 Tips:"
    echo "   • Details: git diff upstream/$target_branch..$CUSTOM_BRANCH -- <file>"
    echo "   • Update: $0 deploy $target_branch"
    echo "   • Deploy without update: $0 deploy --no-upstream"
}
#-------------------------------------------------------------------------------
# ⚡ ACCEPT-UPSTREAM: Accept All Changes
#-------------------------------------------------------------------------------
cmd_accept_upstream() {
    ensure_webui_dir
    cd "$WEBUI_DIR"
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}⚡ ACCEPT-UPSTREAM: Accept Changes${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    echo -e "${RED}⚠️  WARNING!${NC}"
    echo "This script will accept ALL changes from upstream, overwriting local conflicts."
    echo "📂 Working directory: $(pwd)"
    echo ""
    read -p "Are you sure? Type 'yes' to confirm: " confirm
    if [ "$confirm" != "yes" ]; then
        log_warn "Cancelled by user."
        exit 0
    fi
    log_info "Applying changes..."
    log_cmd "git checkout --theirs ."
    git checkout --theirs .
    log_cmd "git add ."
    git add .
    log_cmd "git commit ..."
    git commit -m "Merge upstream: accept all changes" || {
        log_warn "No changes to commit."
    }
    log_ok "All changes accepted and committed."
}
#-------------------------------------------------------------------------------
# ❓ HELP
#-------------------------------------------------------------------------------
show_help() {
    cat << EOF
🦌 webui-tool.sh — Universal Multitool for Open WebUI
Usage:
  $0 <command> [arguments]
Commands:
  deploy [main|dev] [pr:<num>] [--build-only] [--no-upstream]
      Build and deploy project.
      Options:
        --build-only    Build only, no deploy
        --no-upstream   Deploy current custom branch WITHOUT upstream update
                        (preserves all local changes, no fetch/merge)
      Examples:
        $0 deploy                    # Build from main + deploy
        $0 deploy dev                # Build from dev + deploy
        $0 deploy pr:1234            # Build main + PR #1234 + deploy
        $0 deploy dev pr:1234        # Build dev + PR #1234 + deploy
        $0 deploy --build-only       # Build only, no deploy
        $0 deploy --no-upstream      # Deploy current custom WITHOUT update
  check [main|dev]
      Check repository status, compare with upstream.
      Example: $0 check dev
  accept-upstream
      Accept all changes from upstream, overwriting conflicts.
      Requires 'yes' confirmation.
  help
      Show this help.
Requirements:
  • Git, Python 3, curl
  • For deploy: root privileges (sudo)
  • Node.js installed automatically via NVM
EOF
}
#-------------------------------------------------------------------------------
# 🚀 MAIN
#-------------------------------------------------------------------------------
if [ $# -eq 0 ]; then
    show_help
    exit 0
fi
command="$1"
shift
case "$command" in
    deploy)
        cmd_deploy "$@"
        ;;
    check)
        cmd_check "$@"
        ;;
    accept-upstream)
        cmd_accept_upstream
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_err "Unknown command: $command"
        show_help
        exit 1
        ;;
esac
