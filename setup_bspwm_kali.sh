#!/usr/bin/env bash
###############################################################################
#
#  setup_bspwm_kali.sh
#  ---------------------------------------------------------------------------
#  Automatiza la instalación y configuración de bspwm + sxhkd + picom
#  + rofi corriendo encima de una sesión XFCE en Kali Linux.
#
###############################################################################

set -uo pipefail

### ============================ CONFIGURACIÓN ============================ ###

LOG_FILE="$HOME/bspwm_setup_$(date +%Y%m%d_%H%M%S).log"
TOP_PADDING=28
COMPOSITOR=""
STEPS_OK=0
STEPS_WARN=0
STEPS_FAIL=0

### ============================ COLORES / LOG ============================= ###

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC} $*"  | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC} $*"    | tee -a "$LOG_FILE"; STEPS_OK=$((STEPS_OK+1)); }
warn()    { echo -e "${YELLOW}[AVISO]${NC} $*" | tee -a "$LOG_FILE"; STEPS_WARN=$((STEPS_WARN+1)); }
err()     { echo -e "${RED}[ERROR]${NC} $*"   | tee -a "$LOG_FILE" >&2; STEPS_FAIL=$((STEPS_FAIL+1)); }

die() {
    err "$1"
    err "El script se detuvo. Revisa el log en: $LOG_FILE"
    exit 1
}

run_critical() {
    local desc="$1"; shift
    log "Ejecutando: $desc"
    if "$@" >> "$LOG_FILE" 2>&1; then
        success "$desc"
    else
        die "Falló (paso crítico): $desc"
    fi
}

run_optional() {
    local desc="$1"; shift
    log "Ejecutando (opcional): $desc"
    if "$@" >> "$LOG_FILE" 2>&1; then
        success "$desc"
    else
        warn "Falló (se continúa): $desc"
    fi
}

backup_if_exists() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$backup" || die "No se pudo crear el respaldo de '$file'"
    fi
}

### ============================ VALIDACIONES ============================== ###

preflight_checks() {
    log "=== Validaciones previas ==="
    if [[ "$EUID" -eq 0 ]]; then die "No ejecutes como root/sudo."; fi
    sudo -v || die "Se requieren privilegios sudo."
    sudo apt-get update -qq >/dev/null 2>&1 || die "Fallo al actualizar repositorios."
    success "Validaciones correctas"
}

### ============================ INSTALACIÓN =============================== ###

install_packages() {
    log "=== Instalando paquetes base ==="
    # NOTA: Cambiado xterm por qterminal
    run_critical "Instalar bspwm, sxhkd, rofi, qterminal, wmctrl" \
        sudo apt-get install -y bspwm sxhkd rofi qterminal wmctrl

    if apt-cache show picom &>/dev/null; then
        run_critical "Instalar picom" sudo apt-get install -y picom
        COMPOSITOR="picom"
    else
        die "No se encontró picom en los repositorios."
    fi
}

### ============================ DIRECTORIOS ================================ ###

create_directories() {
    log "=== Creando directorios ==="
    for dir in "$HOME/.config/bspwm" "$HOME/.config/sxhkd" \
               "$HOME/.config/$COMPOSITOR" "$HOME/.config/rofi" \
               "$HOME/.config/autostart"; do
        mkdir -p "$dir" || die "Fallo creando $dir"
    done
    success "Directorios creados"
}

### ============================ FIXES DE XFCE ============================== ###

tweak_xfce_session() {
    log "=== Aplicando fixes a XFCE (Evitar Pantalla Negra) ==="
    
    # Apagar el compositor de xfwm4 para evitar que choque con picom
    run_optional "Desactivar compositor nativo de xfwm4" \
        xfconf-query -c xfwm4 -p /general/use_compositing -s false --create -t bool
    
    # Limpiar caché de sesión para evitar que xfwm4 y bspwm arranquen juntos
    log "Limpiando ~/.cache/sessions/..."
    rm -rf "$HOME/.cache/sessions/"*
    success "Caché de sesiones limpiada con éxito"

    # Eliminar atajos viejos
    run_optional "Quitar /commands/custom" xfconf-query -c xfce4-keyboard-shortcuts -p /commands/custom -r -R
    run_optional "Quitar /xfwm4/custom" xfconf-query -c xfce4-keyboard-shortcuts -p /xfwm4/custom -r -R
}

### ============================ CONFIGURACIONES ============================ ###

create_bspwmrc() {
    log "=== Creando bspwmrc ==="
    local target="$HOME/.config/bspwm/bspwmrc"
    backup_if_exists "$target"

    cat > "$target" << EOF
#! /bin/sh
bspc monitor -d I II III IV V VI VII VIII IX X

bspc config border_width         2
bspc config window_gap           12
bspc config split_ratio          0.52
bspc config borderless_monocle   true
bspc config gapless_monocle      true
bspc config top_padding          ${TOP_PADDING}

bspc config pointer_modifier mod1
bspc config pointer_action1 resize_side
bspc config pointer_action2 resize_corner
bspc config pointer_action3 move

bspc rule -a xfce4-panel state=floating layer=above border=off focus=off
EOF
    chmod +x "$target" || die "Error dando permisos a bspwmrc"
    success "bspwmrc creado"
}

create_sxhkdrc() {
    log "=== Creando sxhkdrc ==="
    local target="$HOME/.config/sxhkd/sxhkdrc"
    backup_if_exists "$target"

    cat > "$target" << 'EOF'
# --- Terminal ---
super + Return
    qterminal

# --- Recargar configuración de sxhkd ---
super + Escape
    pkill -USR1 -x sxhkd

# --- Cerrar ventana ---
super + q
    bspc node -c

# --- Rofi: lanzar aplicaciones ---
super + d
    rofi -show run

# --- Rofi: cambiar ventanas ---
super + Tab
    rofi -show window

# --- Layouts ---
F1
    bspc node @/ -R 90
F2
    bspc node -f next.local
F3
    bspc node @/ -F horizontal
F4
    bspc node @/ -F vertical

# --- Navegar entre desktops ---
super + {Left,Right}
    bspc desktop -f {prev.local,next.local}

# --- Navegar entre ventanas ---
super + {Up,Down}
    bspc node -f {next,prev}.local

# --- Mover ventana a otro desktop ---
super + shift + {1-9,0}
    bspc node -d '^{1-9,10}'

# --- Ir a desktop por número ---
super + {1-9,0}
    bspc desktop -f '^{1-9,10}'
EOF
    success "sxhkdrc creado (usando tecla Super)"
}

create_compositor_config() {
    log "=== Creando picom.conf ==="
    local target="$HOME/.config/picom/picom.conf"
    backup_if_exists "$target"

    cat > "$target" << 'EOF'
backend = "glx";
glx-copy-from-front = false;

shadow = true;
shadow-radius = 7;
shadow-offset-x = -7;
shadow-offset-y = -7;
shadow-opacity = 0.7;
shadow-exclude = [
    "name = 'Notification'",
    "class_g = 'Conky'",
    "_GTK_FRAME_EXTENTS@"
];

menu-opacity = 1;
inactive-window-opacity = 1;
inactive-opacity = 0.80;
active-opacity = 1;
frame-opacity = 1;
detect-rounded-corners = true;
detect-client-opacity = true;
focus-exclude = [ "name = 'rofi'" ];

fading = true;
fade-delta = 4;
fade-in-step = 0.03;
fade-out-step = 0.03;
EOF
    success "picom.conf creado sin warnings"
}

create_autostart_entries() {
    log "=== Creando autostart ==="
    local autostart_dir="$HOME/.config/autostart"

    cat > "${autostart_dir}/bspwm.desktop" << EOF
[Desktop Entry]
Type=Application
Name=BSPWM Tiling WM
Exec=bspwm
OnlyShowIn=XFCE;
StartupNotify=false
Terminal=false
Hidden=false
EOF

    cat > "${autostart_dir}/sxhkd.desktop" << EOF
[Desktop Entry]
Type=Application
Name=SXHKD Daemon
Exec=sxhkd
OnlyShowIn=XFCE;
StartupNotify=false
Terminal=false
Hidden=false
EOF

    cat > "${autostart_dir}/picom.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Picom Compositor
Exec=picom --config ${HOME}/.config/picom/picom.conf -b
OnlyShowIn=XFCE;
StartupNotify=false
Terminal=false
Hidden=false
EOF
    success "Archivos de autostart creados"
}

### ============================ PASO MANUAL ================================ ###

manual_step_xfwm4() {
    echo -e "${YELLOW}${BOLD}============================================================${NC}"
    echo -e "${YELLOW}${BOLD} PASO MANUAL OBLIGATORIO (Para evitar bugs del sistema)     ${NC}"
    echo -e "${YELLOW}${BOLD}============================================================${NC}"
    echo "1. Ve a: Configuración -> Sesión e Inicio (Session and Startup)"
    echo "2. Pestaña 'Sesión' (Session)"
    echo "3. Busca 'xfwm4' en la lista y cámbialo a 'Nunca' (Never)"
    echo "4. Da clic en el botón 'Guardar Sesión' (Save Session) abajo."
    echo
    read -rp "Presiona ENTER cuando hayas guardado la sesión para finalizar... "
}

### ============================ MAIN ======================================== ###

main() {
    log "Iniciando instalación optimizada para Kali Linux"
    preflight_checks
    install_packages
    create_directories
    tweak_xfce_session
    create_bspwmrc
    create_sxhkdrc
    create_compositor_config
    create_autostart_entries
    manual_step_xfwm4

    echo -e "${GREEN}${BOLD}¡Automatización completada!${NC}"
    echo "Por favor REINICIA TU COMPUTADORA ahora para aplicar los cambios en limpio."
}

main "$@"