#!/bin/bash
#===============================================================================
# 🦌 webui-tool.sh — Универсальный мультитул для Open WebUI
#===============================================================================
# Объединяет функции сборки, деплоя, проверки изменений и разрешения конфликтов.
#
# Использование:
#   ./webui-tool.sh deploy [main|dev] [pr:<num>] [--build-only] [--no-upstream]
#       Сборка и деплой (или только сборка с --build-only)
#       Опция --no-upstream: деплой текущей кастомной ветки БЕЗ обновления из upstream
#
#   ./webui-tool.sh check [main|dev]
#       Проверка состояния репозитория, сравнение с upstream
#
#   ./webui-tool.sh accept-upstream
#       Принять все изменения из upstream, перезаписав локальные конфликты
#
#   ./webui-tool.sh help
#       Показать справку
#
# Требования: Git, Python 3, curl, Node.js (устанавливается автоматически)
#===============================================================================
set -e
#-------------------------------------------------------------------------------
# 🔧 КОНФИГУРАЦИЯ
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
# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
#-------------------------------------------------------------------------------
# 🛠️ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
#-------------------------------------------------------------------------------
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }
log_cmd()  { echo -e "${CYAN}[CMD]${NC} $1"; }
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Требуются права root."
        log_info "Запустите: sudo $0 $*"
        exit 1
    fi
}
ensure_webui_dir() {
    if [ ! -d "$WEBUI_DIR" ]; then
        log_err "Директория $WEBUI_DIR не найдена."
        log_info "Сначала выполните: $0 deploy"
        exit 1
    fi
}
install_node() {
    if [ ! -d "$NVM_DIR" ]; then
        log_info "Установка NVM..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash
        source "$NVM_DIR/nvm.sh"
    else
        source "$NVM_DIR/nvm.sh"
    fi
    if [ -z "$(nvm current 2>/dev/null | grep '^v22')" ]; then
        log_info "Установка Node.js 22..."
        nvm install 22
        nvm alias default 22
    fi
    nvm use 22 > /dev/null 2>&1
}
#-------------------------------------------------------------------------------
# 📦 DEPLOY: Сборка и деплой
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
            *) log_err "Неизвестный аргумент: $arg"; show_help; exit 1 ;;
        esac
    done
    # Валидация комбинаций
    if [ "$no_upstream" = true ] && [ -n "$pr_number" ]; then
        log_err "Нельзя использовать --no-upstream вместе с PR!"
        log_info "PR требует обновления из upstream для применения патча."
        exit 1
    fi
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}🚀 DEPLOY: Сборка и установка${NC}"
    echo -e "${YELLOW}========================================${NC}"
    local mode_desc="Режим: $target_branch"
    [ -n "$pr_number" ] && mode_desc="$mode_desc + PR #$pr_number"
    [ "$build_only" = true ] && mode_desc="$mode_desc (только сборка)"
    [ "$no_upstream" = true ] && mode_desc="Режим: ТОЛЬКО КАСТОМ (--no-upstream)"
    log_info "$mode_desc"
    # Подготовка репозитория
    if [ "$no_upstream" = true ]; then
        setup_repo_no_upstream
    else
        setup_repo "$target_branch" "$pr_number"
    fi
    # Сборка
    build_backend
    build_frontend
    # Деплой
    if [ "$build_only" = true ]; then
        log_ok "Сборка завершена. Деплой пропущен (--build-only)."
        log_info "Для деплоя: sudo $0 deploy $target_branch ${pr_number:+pr:$pr_number}"
    else
        update_prod
    fi
    echo ""
    log_ok "🎉 Все операции завершены успешно!"
}
setup_repo_no_upstream() {
    ensure_webui_dir
    cd "$WEBUI_DIR"
    log_info "Работа с текущей кастомной веткой без обновления из upstream..."
    local current_branch=$(git branch --show-current)
    if [ "$current_branch" != "$CUSTOM_BRANCH" ]; then
        log_info "Переключение на $CUSTOM_BRANCH..."
        git checkout "$CUSTOM_BRANCH"
    fi
    if [ -n "$(git status --porcelain)" ]; then
        log_warn "Обнаружены незакоммиченные изменения в рабочей директории!"
        log_info "Изменения будут использованы как есть. Рекомендуется закоммитить их перед деплоем."
        echo ""
        git status --short | sed 's/^/   /'
        echo ""
    else
        log_ok "Рабочая директория чиста."
    fi
    local last_commit=$(git log -1 --oneline)
    log_info "Текущий коммит: $last_commit"
    log_ok "Готово. Будет собрано текущее состояние $CUSTOM_BRANCH."
}
setup_repo() {
    local target_branch="$1"
    local pr_number="$2"
    if [ ! -d "$WEBUI_DIR" ]; then
        log_info "Клонирование репозитория..."
        mkdir -p "$(dirname "$WEBUI_DIR")"
        git clone "$REPO_URL" "$WEBUI_DIR"
        cd "$WEBUI_DIR"
        git checkout -b "$CUSTOM_BRANCH"
        log_ok "Репозиторий клонирован, ветка $CUSTOM_BRANCH создана."
        return
    fi
    cd "$WEBUI_DIR"
    if ! git remote | grep -q "upstream"; then
        git remote add upstream "$REPO_URL"
    fi
    git fetch upstream
    if ! git show-ref --verify --quiet refs/heads/$CUSTOM_BRANCH; then
        log_err "Ветка $CUSTOM_BRANCH не существует!"
        exit 1
    fi
    local current_branch=$(git branch --show-current)
    local stashed=false
    log_info "Обновление ветки $target_branch..."
    if [ "$current_branch" = "$target_branch" ]; then
        git reset --hard "upstream/$target_branch"
    elif [ "$current_branch" = "$CUSTOM_BRANCH" ]; then
        if [ -n "$(git status --porcelain)" ]; then
            log_warn "Есть незакоммиченные изменения, stash..."
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
    log_info "Мерж в $CUSTOM_BRANCH..."
    git checkout "$CUSTOM_BRANCH"
    if [ "$stashed" = true ]; then
        git stash pop || {
            log_err "Конфликт при восстановлении stash!"
            exit 1
        }
    fi
    if git merge "$target_branch" --no-commit --no-ff; then
        if [ -n "$(git status --porcelain)" ]; then
            local msg="Merge upstream/$target_branch"
            [ -n "$pr_number" ] && msg="$msg + PR #$pr_number"
            git commit -m "$msg into custom"
        fi
        log_ok "Мерж успешен."
    else
        log_err "Конфликт при мерже! Разрешите вручную."
        exit 1
    fi
}
apply_pr() {
    local pr_num="$1"
    local base_branch="$2"
    log_info "Применение Pull Request #$pr_num..."
    local temp_branch="temp-pr-$pr_num"
    git checkout -B "$temp_branch" "$base_branch"
    local patch_url="https://github.com/open-webui/open-webui/pull/${pr_num}.patch"
    log_info "Скачивание патча: $patch_url"
    if curl -sSL "$patch_url" | git am -3; then
        log_ok "PR #$pr_num успешно применён."
    else
        log_err "Ошибка применения PR #$pr_num!"
        echo "Разрешите конфликты вручную:"
        echo "  1. git status"
        echo "  2. Отредактируйте файлы"
        echo "  3. git add <файлы>"
        echo "  4. git am --continue"
        echo "  5. git checkout $CUSTOM_BRANCH && git merge $temp_branch"
        exit 1
    fi
    git checkout "$base_branch"
    git merge "$temp_branch" --no-ff -m "Merge PR #$pr_num into $base_branch"
    git branch -D "$temp_branch"
}
build_backend() {
    log_info "Сборка Backend (Python venv)..."
    cd "$WEBUI_DIR"
    if [ ! -d "venv" ]; then
        log_info "Создание виртуального окружения..."
        python3 -m venv venv
    fi
    source venv/bin/activate
    pip install --upgrade pip -q
    pip install -r backend/requirements.txt -q
    deactivate
    log_ok "Backend готов."
}
build_frontend() {
    log_info "Сборка Frontend..."
    cd "$WEBUI_DIR"
    if [ ! -d "src" ]; then
        log_warn "Папка src не найдена. Пропуск сборки frontend."
        return 0
    fi
    install_node
    cd src
    npm install --silent
    npm run build
    cd ..
    if [ ! -d "build" ]; then
        log_err "Сборка frontend не создала папку build!"
        exit 1
    fi
    log_ok "Frontend готов (build/)."
}
update_prod() {
    log_info "=== 🚀 ДЕПЛОЙ В PRODUCTION ==="
    check_root
    if [[ ! -d "$SOURCE_BACKEND_DIR" ]]; then
        log_err "Backend не найден: $SOURCE_BACKEND_DIR"
        exit 1
    fi
    if [[ ! -d "$SOURCE_FRONTEND_DIR" ]]; then
        log_err "Frontend build не найден: $SOURCE_FRONTEND_DIR"
        exit 1
    fi
    if [[ ! -d "$TARGET_DIR" ]]; then
        log_err "Target dir не найден: $TARGET_DIR"
        exit 1
    fi
    log_info "[1/5] Остановка сервиса $SERVICE_NAME..."
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME"
        log_ok "Сервис остановлен."
    else
        log_warn "Сервис уже остановлен."
    fi
    log_info "[2/5] Очистка целевой директории..."
    cd "$TARGET_DIR"
    for item in *; do
        if [[ "$item" != "data" && "$item" != "frontend" && "$item" != "CHANGELOG.md" ]]; then
            if [[ -e "$item" ]]; then
                echo "  Удаляю: $item"
                rm -rf "$item"
            fi
        else
            echo "  Сохраняю: $item"
        fi
    done
    log_info "[3/5] Обновление frontend..."
    local frontend_target="$TARGET_DIR/frontend"
    if [[ -d "$frontend_target" ]]; then
        rm -rf "$frontend_target"/*
        rm -rf "$frontend_target"/.[!.]* 2>/dev/null || true
    else
        mkdir -p "$frontend_target"
    fi
    cp -rf "$SOURCE_FRONTEND_DIR"/* "$frontend_target/"
    cp -rf "$SOURCE_FRONTEND_DIR"/.[!.]* "$frontend_target/" 2>/dev/null || true
    log_ok "Frontend обновлён."
    log_info "[4/5] Копирование backend..."
    cd "$SOURCE_BACKEND_DIR"
    for item in *; do
        if [[ "$item" != "data" ]]; then
            if [[ -e "$item" ]]; then
                cp -rf "$item" "$TARGET_DIR/"
            fi
        fi
    done
    log_ok "Backend обновлён."
    log_info "[5/5] Запуск сервиса $SERVICE_NAME..."
    systemctl start "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_ok "Сервис запущен."
    else
        log_err "Сервис не запустился! Проверьте: systemctl status $SERVICE_NAME"
        exit 1
    fi
    log_ok "=== ДЕПЛОЙ ЗАВЕРШЕН УСПЕШНО ==="
}
#-------------------------------------------------------------------------------
# 🔍 CHECK: Проверка изменений
#-------------------------------------------------------------------------------
cmd_check() {
    local target_branch="${1:-main}"
    ensure_webui_dir
    cd "$WEBUI_DIR"
    if [[ "$target_branch" != "main" && "$target_branch" != "dev" ]]; then
        log_err "Неверная ветка '$target_branch'. Допустимо: main или dev."
        exit 1
    fi
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}🔍 CHECK: Проверка состояния${NC}"
    echo -e "${YELLOW}========================================${NC}"
    log_info "Обновление информации о ремоутах..."
    git fetch upstream --quiet 2>/dev/null || git fetch upstream
    echo ""
    echo "📊 ОТЧЁТ ПО СОСТОЯНИЮ РЕПОЗИТОРИЯ"
    echo "=================================="
    echo ""
    echo "📍 Текущая ветка:"
    local current=$(git branch --show-current)
    if [ "$current" = "$CUSTOM_BRANCH" ]; then
        echo "   ✅ $current (активна)"
    else
        echo "   ⚠️ $current (ожидалась $CUSTOM_BRANCH)"
    fi
    echo ""
    echo "📜 Последние коммиты в $CUSTOM_BRANCH:"
    git log --oneline -30 "$CUSTOM_BRANCH" | sed 's/^/   /'
    echo ""
    echo "🔄 Статус слияния с upstream/$target_branch:"
    local merge_base=$(git merge-base "$CUSTOM_BRANCH" "upstream/$target_branch")
    local upstream_head=$(git rev-parse "upstream/$target_branch")
    if [ "$merge_base" = "$upstream_head" ]; then
        echo "   ✅ Кастомная ветка содержит все изменения из upstream/$target_branch"
    else
        echo "   ⚠️ Есть новые коммиты в upstream/$target_branch."
        local commits_behind=$(git rev-list --count "$CUSTOM_BRANCH..upstream/$target_branch")
        echo "   📦 Доступно обновлений: $commits_behind коммит(ов)"
    fi
    echo ""
    echo "🔀 Различия между $CUSTOM_BRANCH и upstream/$target_branch:"
    local diff_stat=$(git diff --stat "upstream/$target_branch..$CUSTOM_BRANCH" 2>/dev/null || true)
    if [ -z "$diff_stat" ]; then
        echo "   ℹ️ Нет различий. Код идентичен upstream/$target_branch."
    else
        echo "   Обнаружены кастомные изменения:"
        echo "$diff_stat" | sed 's/^/   /'
    fi
    echo ""
    echo "📝 Файлы с изменениями:"
    local diff_files=$(git diff --name-only "upstream/$target_branch..$CUSTOM_BRANCH" 2>/dev/null || true)
    if [ -z "$diff_files" ]; then
        echo "   (нет изменённых файлов)"
    else
        echo "$diff_files" | sed 's/^/   • /'
    fi
    echo ""
    echo "🔧 Незакоммиченные изменения:"
    local status=$(git status --porcelain 2>/dev/null || true)
    if [ -z "$status" ]; then
        echo "   ✅ Рабочая директория чиста."
    else
        echo "   Обнаружены изменения:"
        echo "$status" | sed 's/^/   /'
    fi
    echo ""
    log_ok "Проверка завершена!"
    echo ""
    echo "💡 Подсказки:"
    echo "   • Детали изменений: git diff upstream/$target_branch..$CUSTOM_BRANCH -- <файл>"
    echo "   • Обновить: $0 deploy $target_branch"
    echo "   • Деплой без обновления: $0 deploy --no-upstream"
}
#-------------------------------------------------------------------------------
# ⚡ ACCEPT-UPSTREAM: Принять все изменения
#-------------------------------------------------------------------------------
cmd_accept_upstream() {
    ensure_webui_dir
    cd "$WEBUI_DIR"
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}⚡ ACCEPT-UPSTREAM: Принять изменения${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    echo -e "${RED}⚠️  ВНИМАНИЕ!${NC}"
    echo "Этот скрипт примет ВСЕ изменения от upstream, перезаписав локальные конфликты."
    echo "📂 Рабочая директория: $(pwd)"
    echo ""
    read -p "Вы уверены? Введите 'yes' для подтверждения: " confirm
    if [ "$confirm" != "yes" ]; then
        log_warn "Отменено пользователем."
        exit 0
    fi
    log_info "Применяем изменения..."
    log_cmd "git checkout --theirs ."
    git checkout --theirs .
    log_cmd "git add ."
    git add .
    log_cmd "git commit ..."
    git commit -m "Merge upstream: accept all changes" || {
        log_warn "Нет изменений для коммита."
    }
    log_ok "Все изменения приняты и закоммичены."
}
#-------------------------------------------------------------------------------
# ❓ HELP
#-------------------------------------------------------------------------------
show_help() {
    cat << EOF
🦌 webui-tool.sh — Универсальный мультитул для Open WebUI
Использование:
  $0 <команда> [аргументы]
Команды:
  deploy [main|dev] [pr:<num>] [--build-only] [--no-upstream]
      Сборка и деплой проекта.
      Опции:
        --build-only    Только сборка, без деплоя
        --no-upstream   Деплой текущей кастомной ветки БЕЗ обновления из upstream
                        (сохраняет все локальные изменения, не делает fetch/merge)
      Примеры:
        $0 deploy                    # Сборка из main + деплой
        $0 deploy dev                # Сборка из dev + деплой
        $0 deploy pr:1234            # Сборка main + PR #1234 + деплой
        $0 deploy dev pr:1234        # Сборка dev + PR #1234 + деплой
        $0 deploy --build-only       # Только сборка, без деплоя
        $0 deploy --no-upstream      # Деплой текущего кастома БЕЗ обновления
  check [main|dev]
      Проверка состояния репозитория, сравнение с upstream.
      Пример: $0 check dev
  accept-upstream
      Принять все изменения из upstream, перезаписав конфликты.
      Требует подтверждения 'yes'.
  help
      Показать эту справку.
Требования:
  • Git, Python 3, curl
  • Для деплоя: права root (sudo)
  • Node.js устанавливается автоматически через NVM
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
        log_err "Неизвестная команда: $command"
        show_help
        exit 1
        ;;
esac
