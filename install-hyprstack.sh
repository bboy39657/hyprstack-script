#!/usr/bin/env bash
# =============================================================================
#  install-hyprstack.sh — установка Hyprstack (hase9awa/hyprstack-shell)
#  для Arch Linux и производных (CachyOS, EndeavourOS, Manjaro).
#
#  Повторяет шаги из INSTALL.md репозитория:
#    1. проверка версий (Hyprland 0.56.2, Quickshell >= 0.3.1, Qt >= 6.9)
#    2. установка зависимостей через pacman (+ AUR-хелпер при необходимости)
#    3. клонирование/обновление исходников и сборка CMake в ~/.local
#    4. резервная копия старого конфига, копирование нового, тема, служба systemd
#
#  Запускать ОТ ОБЫЧНОГО ПОЛЬЗОВАТЕЛЯ (sudo спросит пароль сам, где нужно).
#  Шаг конфигурации лучше выполнять из TTY (Ctrl+Alt+F3), вне Hyprland.
#
#  Примеры:
#    ./install-hyprstack.sh                 # всё целиком, с вопросами
#    ./install-hyprstack.sh --build-only    # из Hyprland: только пакеты и сборка
#    ./install-hyprstack.sh --config-only   # потом из TTY: только конфигурация
#    ./install-hyprstack.sh --update        # обновить через штатный update.sh
# =============================================================================
set -euo pipefail

# ----------------------------- параметры -------------------------------------
REPO_URL="https://github.com/hase9awa/hyprstack-shell.git"
SRC_DIR="${HYPRSTACK_SRC:-$HOME/.local/src/hyprstack-shell}"
REQ_HYPRLAND="0.56.2"
REQ_QUICKSHELL="0.3.1"
REQ_QT="6.9"
DEFAULT_SCHEME="hyprstack-catppuccin"
DEFAULT_MODE="dark"

JOBS=2
ASSUME_YES=0
FORCE=0
DO_DEPS=1
DO_BUILD=1
DO_CONFIG=1
DO_OPTIONAL=ask
DO_UPDATE=0

PACKAGES=(
  base-devel git cmake ninja pkgconf gettext
  hyprland quickshell nlohmann-json qt6-base qt6-declarative qt6-shadertools
  qt6-svg qt6-imageformats qt6-wayland libqalculate lm_sensors
  pixman libdrm libinput systemd-libs wayland libxkbcommon pango cairo
  python python-pillow kitty firefox fuzzel btop pavucontrol
  wl-clipboard cliphist grim slurp wf-recorder swappy libnotify
  brightnessctl networkmanager pipewire pipewire-pulse wireplumber
  polkit hyprlock hyprpicker xdg-utils xdg-user-dirs libxml2 adwaita-icon-theme dbus
)
OPTIONAL_PACKAGES=(bluez bluez-utils upower power-profiles-daemon ddcutil wtype)

# ----------------------------- вывод -----------------------------------------
if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else
  C_B=; C_G=; C_Y=; C_R=; C_C=; C_0=
fi
step() { printf '\n%s==>%s %s%s%s\n' "$C_C" "$C_0" "$C_B" "$*" "$C_0"; }
info() { printf '  %s•%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sОшибка:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

confirm() {  # confirm "вопрос" [y|n по умолчанию]
  local q=$1 def=${2:-y} ans hint
  [[ $def == y ]] && hint="[Y/n]" || hint="[y/N]"
  if (( ASSUME_YES )); then [[ $def == y ]]; return; fi
  read -r -p "  ? $q $hint " ans || ans=
  ans=${ans:-$def}
  [[ ${ans,,} == y* || ${ans,,} == д* ]]
}

usage() {
  cat <<EOF
Использование: $(basename "$0") [опции]

  --build-only        только зависимости и сборка (можно запускать из Hyprland)
  --config-only       только резервная копия и копирование конфигурации
  --skip-deps         не устанавливать пакеты
  --with-optional     поставить доп. пакеты: ${OPTIONAL_PACKAGES[*]}
  --no-optional       не предлагать доп. пакеты
  --update            обновить уже установленный Hyprstack (штатный update.sh)
  --jobs N            потоков сборки (по умолчанию 2; при нехватке RAM — 1)
  --src DIR           каталог исходников (по умолчанию $SRC_DIR)
  -y, --yes           отвечать «да» на все вопросы
  --force             продолжать при несовпадении версий / внутри Hyprland
  -h, --help          эта справка
EOF
}

# ----------------------------- аргументы -------------------------------------
while (($#)); do
  case $1 in
    --build-only)    DO_CONFIG=0 ;;
    --config-only)   DO_DEPS=0; DO_BUILD=0 ;;
    --skip-deps)     DO_DEPS=0 ;;
    --with-optional) DO_OPTIONAL=yes ;;
    --no-optional)   DO_OPTIONAL=no ;;
    --update)        DO_UPDATE=1 ;;
    --jobs)          JOBS=${2:?нужно число}; shift ;;
    --jobs=*)        JOBS=${1#*=} ;;
    --src)           SRC_DIR=${2:?нужен путь}; shift ;;
    --src=*)         SRC_DIR=${1#*=} ;;
    -y|--yes)        ASSUME_YES=1 ;;
    --force)         FORCE=1 ;;
    -h|--help)       usage; exit 0 ;;
    *) die "неизвестная опция: $1 (см. --help)" ;;
  esac
  shift
done
[[ $JOBS =~ ^[1-9][0-9]?$ ]] || die "--jobs должен быть числом от 1 до 99"

# ----------------------------- предпроверки ----------------------------------
(( EUID != 0 )) || die "запускайте от обычного пользователя, не от root/sudo."
command -v pacman >/dev/null || die "pacman не найден — скрипт только для Arch и производных."
command -v sudo   >/dev/null || die "нужен sudo."

in_hyprland() { [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || pgrep -x Hyprland >/dev/null 2>&1; }

# версия без pkgrel/epoch: "1:0.56.2-3" -> "0.56.2"
strip_ver() { local v=${1#*:}; printf '%s' "${v%-*}"; }
repo_ver()  { LC_ALL=C pacman -Si "$1" 2>/dev/null | awk -F': ' '/^Version/{print $2; exit}'; }
local_ver() { LC_ALL=C pacman -Q "$1" 2>/dev/null | awk '{print $2}'; }
ver_ge()    { [[ $(vercmp "$1" "$2") -ge 0 ]]; }

aur_helper() {
  local h; for h in paru yay; do command -v "$h" >/dev/null && { echo "$h"; return; }; done
}

# ----------------------------- режим обновления ------------------------------
if (( DO_UPDATE )); then
  step "Обновление Hyprstack"
  [[ -x $SRC_DIR/update.sh ]] || die "в $SRC_DIR нет update.sh — сначала выполните установку."
  if in_hyprland && (( ! FORCE )); then
    die "update.sh требует выйти из Hyprland. Перейдите в TTY (Ctrl+Alt+F3) и повторите."
  fi
  cd "$SRC_DIR"
  exec ./update.sh --jobs "$JOBS"
fi

# ----------------------------- 1. версии -------------------------------------
check_versions() {
  step "Проверка версий в репозиториях"
  sudo pacman -Sy >/dev/null || warn "не удалось обновить базы pacman"

  local hv qv qtv
  hv=$(strip_ver "$(repo_ver hyprland)")
  qv=$(strip_ver "$(repo_ver quickshell)")
  qtv=$(strip_ver "$(repo_ver qt6-base)")

  info "hyprland  в репозитории: ${hv:-нет}   (нужно ровно $REQ_HYPRLAND)"
  info "quickshell в репозитории: ${qv:-нет}   (нужно >= $REQ_QUICKSHELL)"
  info "qt6-base  в репозитории: ${qtv:-нет}   (нужно >= $REQ_QT)"

  local problems=0
  if [[ $hv != "$REQ_HYPRLAND" ]]; then
    warn "Hyprstack требует Hyprland строго $REQ_HYPRLAND: нативный модуль привязан к ABI."
    warn "В репозитории ${hv:-его нет}. Нужен совместимый пакет (например, из архива ARM или AUR)."
    problems=1
  fi
  if [[ -z $qtv ]] || ! ver_ge "$qtv" "$REQ_QT"; then
    warn "Нужен Qt >= $REQ_QT."; problems=1
  fi
  if [[ -z $qv ]]; then
    QUICKSHELL_FROM_AUR=1
    warn "quickshell нет в репозиториях — попробую поставить из AUR."
  elif ! ver_ge "$qv" "$REQ_QUICKSHELL"; then
    warn "quickshell в репозитории старее $REQ_QUICKSHELL."; problems=1
  fi

  if (( problems )); then
    (( FORCE )) || confirm "Версии не совпадают с требованиями. Всё равно продолжить?" n \
      || die "остановлено. Подготовьте совместимые пакеты и запустите снова (или --force)."
  fi
}

# ----------------------------- 2. пакеты -------------------------------------
QUICKSHELL_FROM_AUR=0
install_deps() {
  step "Установка зависимостей"
  local pkgs=("${PACKAGES[@]}")
  if (( QUICKSHELL_FROM_AUR )); then
    pkgs=("${pkgs[@]/quickshell}")
    local -a clean=(); local p; for p in "${pkgs[@]}"; do [[ -n $p ]] && clean+=("$p"); done
    pkgs=("${clean[@]}")
  fi

  # Не обновляем hyprland поверх уже установленного 0.56.2, если в репо другая версия.
  local hl; hl=$(strip_ver "$(local_ver hyprland)")
  if [[ $hl == "$REQ_HYPRLAND" && $(strip_ver "$(repo_ver hyprland)") != "$REQ_HYPRLAND" ]]; then
    warn "Установлен Hyprland $REQ_HYPRLAND, в репо другая версия — пропускаю обновление hyprland."
    warn "Добавьте 'IgnorePkg = hyprland' в /etc/pacman.conf, чтобы -Syu его не обновил."
    local -a clean=(); local p; for p in "${pkgs[@]}"; do [[ $p != hyprland ]] && clean+=("$p"); done
    pkgs=("${clean[@]}")
    sudo pacman -Syu --needed --ignore hyprland "${pkgs[@]}"
  else
    sudo pacman -Syu --needed "${pkgs[@]}"
  fi

  if (( QUICKSHELL_FROM_AUR )); then
    local h; h=$(aur_helper)
    [[ -n $h ]] || die "нужен AUR-хелпер (paru или yay) для установки quickshell."
    info "Ставлю quickshell через $h"
    "$h" -S --needed quickshell
  fi

  local want=$DO_OPTIONAL
  if [[ $want == ask ]]; then
    confirm "Поставить дополнительные пакеты (${OPTIONAL_PACKAGES[*]})?" y && want=yes || want=no
  fi
  if [[ $want == yes ]]; then
    sudo pacman -S --needed "${OPTIONAL_PACKAGES[@]}"
    if confirm "Включить службу bluetooth?" y; then
      sudo systemctl enable --now bluetooth.service || warn "не удалось включить bluetooth"
    fi
    systemctl is-enabled power-profiles-daemon.service &>/dev/null \
      || sudo systemctl enable --now power-profiles-daemon.service || true
  fi

  # NetworkManager: не включаем молча — может конфликтовать с iwd/systemd-networkd.
  if ! systemctl is-active --quiet NetworkManager.service; then
    warn "NetworkManager не запущен (нужен для сетевого модуля оболочки)."
    if confirm "Включить NetworkManager? (не делайте, если сетью управляет iwd/systemd-networkd/netctl)" n; then
      sudo systemctl enable --now NetworkManager.service
    fi
  fi

  # PipeWire в Arch запускается сокетами пользователя — просто проверим.
  systemctl --user is-enabled pipewire.socket &>/dev/null \
    || systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null \
    || warn "проверьте, что PipeWire/WirePlumber включены"

  # Финальная проверка установленного Hyprland
  hl=$(strip_ver "$(local_ver hyprland)")
  if [[ $hl != "$REQ_HYPRLAND" ]]; then
    warn "Установлен Hyprland ${hl:-?}, а нужен $REQ_HYPRLAND."
    (( FORCE )) || confirm "Собирать всё равно? (модуль может не загрузиться)" n || die "остановлено."
  fi
}

# ----------------------------- 3. сборка -------------------------------------
fetch_sources() {
  step "Исходники: $SRC_DIR"
  if [[ -d $SRC_DIR/.git ]]; then
    info "Каталог уже есть — git pull --ff-only"
    git -C "$SRC_DIR" pull --ff-only || warn "не удалось обновить, собираю текущие исходники"
  else
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone "$REPO_URL" "$SRC_DIR"
  fi
}

build_install() {
  step "Сборка (потоков: $JOBS)"
  local data_home=${XDG_DATA_HOME:-$HOME/.local/share}
  cmake -S "$SRC_DIR" -B "$SRC_DIR/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$HOME/.local" \
    -DCMAKE_INSTALL_DATADIR="$data_home"
  cmake --build "$SRC_DIR/build" --parallel "$JOBS" \
    || die "сборка не удалась. При нехватке памяти попробуйте --jobs 1."
  step "Установка в ~/.local"
  cmake --install "$SRC_DIR/build"
  info "Список установленных файлов: $SRC_DIR/build/install_manifest.txt"
}

# ----------------------------- 4. конфигурация -------------------------------
ensure_path() {
  local line='export PATH="$HOME/.local/bin:$PATH"  # hyprstack'
  local profile
  case ${SHELL##*/} in
    zsh)  profile=${ZDOTDIR:-$HOME}/.zprofile ;;
    bash) profile=$HOME/.bash_profile ;;
    *)    profile=$HOME/.profile ;;
  esac
  if [[ :$PATH: != *":$HOME/.local/bin:"* ]] && ! grep -qs '# hyprstack' "$profile"; then
    printf '\n%s\n' "$line" >>"$profile"
    info "Добавил ~/.local/bin в PATH ($profile)"
  fi
  export PATH="$HOME/.local/bin:$PATH"
}

configure() {
  step "Конфигурация"
  if in_hyprland && (( ! FORCE )); then
    warn "Сейчас запущен Hyprland. Инструкция требует менять конфиг из TTY."
    warn "Выйдите из сеанса, нажмите Ctrl+Alt+F3, войдите и выполните:"
    warn "  $0 --config-only"
    return 0
  fi
  [[ -d $SRC_DIR/shell/assets/hyprland/config ]] || die "нет исходников в $SRC_DIR — сначала соберите проект."

  local config_dir=${XDG_CONFIG_HOME:-$HOME/.config}
  local backup_dir name moved=0
  backup_dir=$(mktemp -d "$HOME/hyprstack-backup.XXXXXXXX")
  for name in hypr hyprstack systemd/user/hyprstack-session.service; do
    if [[ -e $config_dir/$name || -L $config_dir/$name ]]; then
      mv "$config_dir/$name" "$backup_dir/"; moved=1
    fi
  done
  if (( moved )); then info "Резервная копия старого конфига: ${C_B}$backup_dir${C_0}"
  else rmdir "$backup_dir"; info "Старой конфигурации не было — копия не нужна"; fi

  mkdir -p "$config_dir/hypr" "$config_dir/hyprstack"
  cp -R "$SRC_DIR/shell/assets/hyprland/config/." "$config_dir/hypr/"
  cp -R "$SRC_DIR/distribution/defaults/hyprstack/." "$config_dir/hyprstack/"
  info "Скопирован конфиг Hyprland и Hyprstack"

  ensure_path
  if command -v hyprstack >/dev/null; then
    hyprstack scheme set -n "$DEFAULT_SCHEME" -m "$DEFAULT_MODE" \
      && info "Тема: $DEFAULT_SCHEME ($DEFAULT_MODE)" \
      || warn "не удалось задать тему — сделайте это позже в настройках"
  else
    warn "команда hyprstack не найдена в ~/.local/bin — проверьте сборку"
  fi

  if systemctl --user show-environment &>/dev/null; then
    mkdir -p "$config_dir/systemd/user"
    cp "$SRC_DIR/distribution/systemd/user/hyprstack-session.service" "$config_dir/systemd/user/"
    systemctl --user daemon-reload
    info "Установлена пользовательская служба hyprstack-session.service"
  else
    warn "пользовательский systemd недоступен — оболочка использует встроенный менеджер сеанса"
  fi

  cat <<EOF

  ${C_Y}Не забудьте${C_0} отключить автозапуск прежней панели (waybar и т.п.),
  демона уведомлений (mako/dunst/swaync) и стороннего polkit-агента.
EOF
}

# ----------------------------- запуск ----------------------------------------
printf '%sУстановщик Hyprstack для Arch Linux%s\n' "$C_B" "$C_0"

if (( DO_DEPS )); then check_versions; install_deps; fi
if (( DO_BUILD )); then
  command -v cmake >/dev/null || die "cmake не найден — запустите без --skip-deps."
  fetch_sources; build_install
fi
if (( DO_CONFIG )); then configure; fi

step "Готово"
cat <<EOF
  1. Войдите в Hyprland через менеджер входа или командой ${C_B}start-hyprland${C_0} из TTY.
  2. В терминале (Super+Return) проверьте:
       ${C_B}hyprstack-doctor${C_0}
       ${C_B}hyprctl configerrors${C_0}
  3. Переключение scrolling / stacking — Super+Ctrl+Shift+M, дашборд — Super.

  Обновление позже:  $0 --update   (из TTY)
  Исходники:         $SRC_DIR
EOF
