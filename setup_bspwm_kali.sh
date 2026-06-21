#!/usr/bin/env bash
###############################################################################
#
#  setup_bspwm_kali.sh (Versión Híbrida XFCE+Bspwm Definitiva)
#  ---------------------------------------------------------------------------
#  Soluciona el deadlock de X11 usando un Wrapper Script (Estilo AutoBspwm).
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

log()     { echo -e "${BLUE}[INFO]${NC} $*"   | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC} $*"     | tee -a "$LOG_FILE"; STEPS_OK=$((STEPS_OK+1)); }
warn()    { echo -e "${YELLOW}[AVISO]${NC} $*" | tee -a "$LOG_FILE"; STEPS_WARN=$((STEPS_WARN+1)); }
err()     { echo -e "${RED}[ERROR]${NC} $*"    | tee -a "$LOG_FILE" >&2; STEPS_FAIL=$((STEPS_FAIL+1)); }

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

backup_if_exists() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$backup" || die "No se pudo respaldar '$file'"
    fi
}

### ============================ VALIDACIONES ============================== ###

preflight_checks() {
    log "=== Validaciones previas ==="
    if [[ "$EUID" -eq 0 ]]; then die "No ejecutes como root/sudo."; fi
    sudo -v || die "Se requieren privilegios sudo."
    sudo apt-get update -qq >/dev/null 2>&1 || die "Fallo al actualizar repositorios."
}

### ============================ INSTALACIÓN =============================== ###

install_packages() {
    log "=== Instalando paquetes base ==="
    run_critical "Instalar bspwm, sxhkd, rofi, qterminal, wmctrl" \
        sudo apt-get install -y bspwm sxhkd rofi qterminal wmctrl

    if apt-cache show picom &>/dev/null; then
        run_critical "Instalar picom" sudo apt-get install -y picom
        COMPOSITOR="picom"
    else
        die "Ni picom ni compton están disponibles."
    fi
}

create_directories() {
    log "=== Creando directorios ==="
    for dir in "$HOME/.config/bspwm" "$HOME/.config/sxhkd" \
               "$HOME/.config/$COMPOSITOR" "$HOME/.config/rofi" \
               "$HOME/.config/autostart" "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"; do
        mkdir -p "$dir" || die "Fallo creando $dir"
    done
    success "Directorios creados"
}

### ============================ MITIGACIÓN DE XFWM4 ======================== ###

nuke_xfce_shortcuts() {
    log "=== Aniquilando atajos de XFCE desde la raíz ==="
    # Matar el demonio para que no sobrescriba nuestros cambios
    killall xfconfd 2>/dev/null || true
    sleep 1

    # Sobrescribir el XML con un perfil completamente vacío
    cat > "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-keyboard-shortcuts" version="1.0">
  <property name="commands" type="empty">
    <property name="custom" type="empty"/>
  </property>
  <property name="xfwm4" type="empty">
    <property name="custom" type="empty"/>
  </property>
</channel>
EOF
    success "Atajos de XFCE neutralizados mediante XML"
}

create_bspwm_launcher() {
    log "=== Creando Wrapper de mitigación (Estilo AutoBspwm) ==="
    # Este script es el secreto. Mata xfwm4 ANTES de llamar a bspwm.
    local launcher="$HOME/.config/bspwm/bspwm_launcher.sh"
    cat > "$launcher" << 'EOF'
#!/bin/bash
# 1. Matar xfwm4 sin piedad y quitar composición nativa
xfconf-query -c xfwm4 -p /general/use_compositing -s false --create -t bool 2>/dev/null
killall -9 xfwm4 2>/dev/null

# 2. Darle tiempo al servidor X para que suelte el bloqueo (lock)
sleep 0.5

# 3. Iniciar bspwm de forma limpia
exec bspwm
EOF
    chmod +x "$launcher"
    success "bspwm_launcher creado"
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

bspc config pointer_modifier mod4
bspc config pointer_action1 resize_side
bspc config pointer_action2 resize_corner
bspc config pointer_action3 move

bspc rule -a xfce4-panel state=floating layer=above border=off focus=off
EOF
    chmod +x "$target"
    success "bspwmrc creado (limpio de pkill inútiles)"
}

create_sxhkdrc() {
    log "=== Creando sxhkdrc ==="
    local target="$HOME/.config/sxhkd/sxhkdrc"
    backup_if_exists "$target"

    cat > "$target" << 'EOF'
super + Return
    qterminal

super + Escape
    pkill -USR1 -x sxhkd

super + q
    bspc node -c

super + d
    rofi -show run

super + Tab
    rofi -show window

F1
    bspc node @/ -R 90
F2
    bspc node -f next.local
F3
    bspc node @/ -F horizontal
F4
    bspc node @/ -F vertical

super + {Left,Right}
    bspc desktop -f {prev.local,next.local}

super + {Up,Down}
    bspc node -f {next,prev}.local

super + shift + {1-9,0}
    bspc node -d '^{1-9,10}'

super + {1-9,0}
    bspc desktop -f '^{1-9,10}'
EOF
    success "sxhkdrc creado"
}

create_compositor_config() {
    log "=== Creando configuración de picom ==="
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
    success "picom.conf creado"
}

create_autostart_entries() {
    log "=== Creando entradas de autostart ==="
    local autostart_dir="$HOME/.config/autostart"

    # AQUI ESTA LA MAGIA: Llamamos al Wrapper, NO a bspwm directamente
    cat > "${autostart_dir}/bspwm.desktop" << EOF
[Desktop Entry]
Type=Application
Name=BSPWM Tiling WM
Exec=${HOME}/.config/bspwm/bspwm_launcher.sh
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
    success "Archivos de autostart inyectados con éxito"
}

clear_session_cache() {
    log "=== Purgando caché de sesiones previas ==="
    # Necesario para que no revivan terminales viejas ni configuraciones rotas
    rm -rf "$HOME/.cache/sessions/"*
    
    # Desactivar autoguardado de sesión en XFCE para siempre
    xfconf-query -c xfce4-session -p /general/SaveOnExit -s false --create -t bool 2>/dev/null || true
    success "Caché limpiada y autoguardado desactivado"
}

### ============================ MAIN ======================================== ###

main() {
    log "Iniciando instalación Definitiva"
    preflight_checks
    install_packages
    create_directories
    
    nuke_xfce_shortcuts
    create_bspwm_launcher
    
    create_bspwmrc
    create_sxhkdrc
    create_compositor_config
    create_autostart_entries
    clear_session_cache

    echo
    echo -e "${GREEN}${BOLD}============================================================${NC}"
    echo -e "${GREEN}${BOLD} ¡Instalación completada (100% Desatendida)!                ${NC}"
    echo -e "${GREEN}${BOLD}============================================================${NC}"
    echo -e "${YELLOW}Ya NO necesitas hacer pasos manuales.${NC}"
    echo "Reinicia tu máquina virtual para aplicar los cambios:"
    echo "Ejecuta: sudo reboot"
    echo
}

main "$@"