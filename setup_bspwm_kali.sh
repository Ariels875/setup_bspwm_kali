#!/usr/bin/env bash
###############################################################################
#
#  setup_bspwm_kali.sh (v2 - corregido, sin hacks que rompen la sesión)
#  ---------------------------------------------------------------------------
#  Automatiza bspwm + sxhkd + picom + rofi sobre una sesión XFCE en Kali.
#
#  CAMBIOS RESPECTO A LA VERSIÓN QUE CAUSÓ EL CONGELAMIENTO:
#
#  ELIMINADO (causaba el problema):
#    - rm -rf ~/.cache/sessions/*  --> esto BORRABA el ajuste guardado de
#      "xfwm4 = Never" que ya funcionaba, forzando a xfwm4 a volver a
#      arrancar en la siguiente sesión.
#    - sed sobre xfce4-session.xml --> ese archivo NO es el que XFCE usa
#      para decidir el window manager de la sesión normal (solo aplica a
#      la sesión "Failsafe" de emergencia). Editarlo no tenía ningún
#      efecto real, solo riesgo de corromper configuración general.
#    - autostart xfwm4.desktop con Hidden=true --> xfwm4 NO se inicia vía
#      el mecanismo de autostart XDG, se inicia directamente desde
#      xfce4-session. Este archivo no lo detiene, es un no-op.
#    - Inyección en /sessions/Failsafe/Client0_Command --> solo afecta la
#      sesión de emergencia, nunca se usa en un login normal.
#
#  AÑADIDO (la red de seguridad real):
#    - bspwmrc ahora mata a xfwm4 (pkill -x xfwm4) en su primera línea de
#      ejecución. Esto es INDEPENDIENTE de si el ajuste de sesión de XFCE
#      "se mantiene" o no: si xfwm4 llegara a arrancar, bspwm lo mata en
#      el instante en que él mismo arranca, evitando que dos gestores de
#      ventanas compitan por el teclado/mouse (la causa real del freeze).
#
#  SIGUE SIENDO MANUAL (y debe seguir siéndolo):
#    - Desactivar xfwm4 vía Settings Manager -> Session and Startup ->
#      Session -> xfwm4 -> "Never". Esto escribe el ajuste en
#      ~/.cache/sessions/xfce4-session-HOSTNAME:DISPLAY, un archivo que
#      solo la sesión gráfica viva puede actualizar correctamente (vía
#      D-Bus/XSMP). Editar ese archivo a mano desde un script demostradamente
#      NO tiene efecto confiable (reportado por otros usuarios de XFCE).
#      Por eso NO lo intentamos automatizar — pero gracias al pkill en
#      bspwmrc, ni siquiera es estrictamente necesario que este paso
#      "se mantenga" para evitar el freeze.
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
        die "Falló (paso crítico): $desc  ->  comando: $*"
    fi
}

run_optional() {
    local desc="$1"; shift
    log "Ejecutando (opcional): $desc"
    if "$@" >> "$LOG_FILE" 2>&1; then
        success "$desc"
    else
        warn "Falló (no crítico, se continúa): $desc  ->  comando: $*"
    fi
}

backup_if_exists() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        if cp "$file" "$backup"; then
            warn "Ya existía '$file' -> respaldado en '$backup'"
        else
            die "No se pudo crear el respaldo de '$file'"
        fi
    fi
}

### ============================ VALIDACIONES PREVIAS ====================== ###

preflight_checks() {
    log "=== Validaciones previas ==="

    if [[ "$EUID" -eq 0 ]]; then
        die "No ejecutes este script como root ni con 'sudo ./script.sh'. Ejecútalo como tu usuario normal."
    fi

    log "Verificando acceso a sudo (puede pedir tu contraseña)..."
    sudo -v || die "Se requieren privilegios sudo para instalar paquetes."
    success "Acceso sudo confirmado"

    log "Verificando repositorios..."
    sudo apt-get update -qq >> "$LOG_FILE" 2>&1 || die "Fallo al actualizar repositorios (revisa tu conexión)."
    success "Repositorios actualizados"

    # Advertencia defensiva: si por error alguna versión vieja de este
    # script (o cualquier otro proceso) sigue corriendo, avisamos.
    if [[ -d "$HOME/.cache/sessions" ]] && [[ -z "$(ls -A "$HOME/.cache/sessions" 2>/dev/null)" ]]; then
        warn "Tu carpeta ~/.cache/sessions está vacía. Si antes habías configurado"
        warn "'xfwm4 = Never' manualmente, ese ajuste ya no existe y deberás"
        warn "rehacerlo (Settings Manager -> Session and Startup -> Session)."
        warn "Esto NO es un error del script, solo te informamos del estado actual."
    fi
}

### ============================ INSTALACIÓN =============================== ###

install_packages() {
    log "=== Instalando paquetes base ==="
    run_critical "Instalar bspwm, sxhkd, rofi, qterminal, wmctrl" \
        sudo apt-get install -y bspwm sxhkd rofi qterminal wmctrl

    if command -v picom &>/dev/null; then
        COMPOSITOR="picom"
        success "picom ya está instalado"
    elif apt-cache show picom &>/dev/null; then
        run_critical "Instalar picom" sudo apt-get install -y picom
        COMPOSITOR="picom"
    elif command -v compton &>/dev/null; then
        COMPOSITOR="compton"
        success "compton ya está instalado"
    elif apt-cache show compton &>/dev/null; then
        run_critical "Instalar compton" sudo apt-get install -y compton
        COMPOSITOR="compton"
    else
        die "Ni picom ni compton están disponibles en tus repositorios."
    fi
    log "Compositor seleccionado: ${BOLD}${COMPOSITOR}${NC}"
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

### ============================ ATAJOS XFCE (seguro) ======================= ###

remove_xfce_hotkeys() {
    log "=== Eliminando atajos de teclado personalizados de XFCE ==="
    # Esto SÍ es seguro y SÍ funciona: solo borra atajos personalizados,
    # no toca el estado de sesión ni el window manager.
    run_optional "Quitar /commands/custom" \
        xfconf-query -c xfce4-keyboard-shortcuts -p /commands/custom -r -R
    run_optional "Quitar /xfwm4/custom" \
        xfconf-query -c xfce4-keyboard-shortcuts -p /xfwm4/custom -r -R
}

### ============================ CONFIGURACIONES ============================ ###

create_bspwmrc() {
    log "=== Creando bspwmrc (con red de seguridad anti doble-WM) ==="
    local target="$HOME/.config/bspwm/bspwmrc"
    backup_if_exists "$target"

    cat > "$target" << EOF
#! /bin/sh

# ------------------------------------------------------------------
# RED DE SEGURIDAD: si xfwm4 llegara a estar corriendo (porque el
# ajuste de sesión de XFCE no se guardó, o porque la sesión es nueva
# y todavía no se ha hecho el paso manual), lo matamos AQUÍ, antes de
# que bspwm tome el control. Esto evita el escenario de "dos window
# managers compitiendo por el teclado/mouse" que causaba el freeze.
# Es inofensivo si xfwm4 no está corriendo (pkill simplemente no hace nada).
# ------------------------------------------------------------------
pkill -x xfwm4 2>/dev/null

# --- Monitors & Desktops ---
bspc monitor -d I II III IV V VI VII VIII IX X

# --- Global settings ---
bspc config border_width         2
bspc config window_gap           12
bspc config split_ratio          0.52
bspc config borderless_monocle   true
bspc config gapless_monocle      true
bspc config top_padding          ${TOP_PADDING}

# --- Mouse settings ---
bspc config pointer_modifier mod4
bspc config pointer_action1 resize_side
bspc config pointer_action2 resize_corner
bspc config pointer_action3 move

# --- Rules ---
bspc rule -a xfce4-panel state=floating layer=above border=off focus=off
EOF

    if [[ $? -ne 0 ]]; then
        die "No se pudo escribir bspwmrc"
    fi
    chmod +x "$target" || die "Error dando permisos a bspwmrc"
    success "bspwmrc creado con red de seguridad anti doble-WM"
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
F5
    bspc desktop -l next
F6
    bspc node @/ -B
F7
    bspc config -d focused window_gap $((`bspc config -d focused window_gap` + 2))
F8
    bspc config -d focused window_gap $((`bspc config -d focused window_gap` - 2))
F9
    bspc node -t floating
F10
    bspc node -t tiled
F11
    bspc node -t pseudo_tiled
F12
    bspc node -t fullscreen

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

    if [[ $? -ne 0 ]]; then
        die "No se pudo escribir sxhkdrc"
    fi
    success "sxhkdrc creado (atajos con tecla Super, sin duplicados)"
}

create_compositor_config() {
    log "=== Creando configuración de ${COMPOSITOR} ==="
    local target="$HOME/.config/${COMPOSITOR}/${COMPOSITOR}.conf"
    backup_if_exists "$target"

    cat > "$target" << 'EOF'
backend = "glx";
glx-no-stencil = true;
glx-copy-from-front = false;

shadow = true;
no-dnd-shadow = true;
no-dock-shadow = true;
shadow-radius = 7;
shadow-offset-x = -7;
shadow-offset-y = -7;
shadow-opacity = 0.7;
shadow-exclude = [
    "name = 'Notification'",
    "class_g = 'Conky'",
    "_GTK_FRAME_EXTENTS@:c"
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

detect-transient = true;
detect-client-leader = true;
EOF

    if [[ $? -ne 0 ]]; then
        die "No se pudo escribir la configuración de ${COMPOSITOR}"
    fi
    success "${COMPOSITOR}.conf creado"
}

create_rofi_config() {
    log "=== Creando configuración de rofi ==="
    local target="$HOME/.config/rofi/config"
    backup_if_exists "$target"

    cat > "$target" << 'EOF'
rofi.color-enabled: true
rofi.color-window: #000000, #000000, #000000
rofi.color-normal: #000000, #00ff00, #000000, #000000, #00ff00
rofi.color-active: #000000, #00ff00, #000000, #000000, #00ff00
rofi.color-urgent: #000000, #ff0000, #000000, #000000, #ff0000
rofi.modi: window,run
rofi.font: Monospace 12
rofi.separator-style: solid
rofi.hide-scrollbar: true
rofi.padding: 5
rofi.lines: 10
EOF

    if [[ $? -ne 0 ]]; then
        die "No se pudo escribir la configuración de rofi"
    fi
    success "Configuración de rofi creada"
}

create_autostart_entries() {
    log "=== Creando entradas de autostart ==="
    local autostart_dir="$HOME/.config/autostart"

    cat > "${autostart_dir}/bspwm.desktop" << EOF
[Desktop Entry]
Type=Application
Name=BSPWM Tiling WM
Comment=Reemplazo de xfwm4
Exec=bspwm
OnlyShowIn=XFCE;
StartupNotify=false
Terminal=false
Hidden=false
EOF
    [[ $? -eq 0 ]] && success "Autostart de bspwm creado" || die "Falló autostart de bspwm"

    cat > "${autostart_dir}/sxhkd.desktop" << EOF
[Desktop Entry]
Type=Application
Name=SXHKD Daemon
Comment=Gestor de atajos para bspwm
Exec=sxhkd
OnlyShowIn=XFCE;
StartupNotify=false
Terminal=false
Hidden=false
EOF
    [[ $? -eq 0 ]] && success "Autostart de sxhkd creado" || die "Falló autostart de sxhkd"

    local conf_path="${HOME}/.config/${COMPOSITOR}/${COMPOSITOR}.conf"
    cat > "${autostart_dir}/${COMPOSITOR}.desktop" << EOF
[Desktop Entry]
Type=Application
Name=${COMPOSITOR^} Compositor
Comment=Efectos visuales y transparencias
Exec=${COMPOSITOR} --config ${conf_path} -b
OnlyShowIn=XFCE;
StartupNotify=false
Terminal=false
Hidden=false
EOF
    [[ $? -eq 0 ]] && success "Autostart de ${COMPOSITOR} creado" || die "Falló autostart de ${COMPOSITOR}"
}

### ============================ FIX DEFENSIVO: ZSH HISTORY ================= ###

fix_zsh_history_if_corrupt() {
    log "=== Verificando integridad del historial de zsh ==="
    local hist="$HOME/.zsh_history"
    [[ -f "$hist" ]] || { log "No existe ~/.zsh_history todavía, nada que revisar."; return; }

    if command -v zsh &>/dev/null && zsh -i -c 'true' 2>&1 | grep -qi "corrupt history"; then
        local backup="${hist}.bak.$(date +%Y%m%d_%H%M%S)"
        mv "$hist" "$backup" && touch "$hist"
        warn "Historial de zsh corrupto respaldado en '$backup' y reiniciado"
    else
        success "El historial de zsh está en buen estado"
    fi
}

### ============================ PASO MANUAL: XFWM4 ========================= ###

manual_step_xfwm4() {
    echo
    echo -e "${YELLOW}${BOLD}============================================================${NC}"
    echo -e "${YELLOW}${BOLD}  PASO MANUAL (sigue siendo necesario, y aquí explico por qué)${NC}"
    echo -e "${YELLOW}${BOLD}============================================================${NC}"
    echo "El ajuste 'xfwm4 = Never' vive en un archivo de caché que SOLO la"
    echo "sesión gráfica activa puede escribir correctamente (vía D-Bus)."
    echo "Editarlo a mano desde un script NO tiene efecto confiable, así que"
    echo "no lo vamos a intentar de nuevo. En su lugar:"
    echo
    echo "  1. Abre: Settings Manager -> Session and Startup"
    echo "  2. Pestaña 'Session'"
    echo "  3. Busca 'xfwm4' en la lista"
    echo "  4. Cambia su modo de inicio a 'Never'"
    echo "  5. Click en 'Save Session'"
    echo
    echo -e "${GREEN}IMPORTANTE: aunque este paso fallara o no se guardara,${NC}"
    echo -e "${GREEN}bspwmrc ya mata a xfwm4 automáticamente (pkill -x xfwm4)${NC}"
    echo -e "${GREEN}en el momento en que bspwm arranca. Eso evita el freeze${NC}"
    echo -e "${GREEN}sin depender de que este ajuste 'se mantenga'.${NC}"
    echo
    echo -e "${RED}NUNCA borres ~/.cache/sessions/ manualmente ni con scripts.${NC}"
    echo -e "${RED}Ahí se guarda este ajuste. Borrarlo fue la causa del problema anterior.${NC}"
    echo
    read -rp "Presiona ENTER cuando hayas completado el paso de arriba para continuar... "
}

### ============================ RESUMEN FINAL =============================== ###

print_summary() {
    echo
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${BOLD}                     RESUMEN DE EJECUCIÓN                    ${NC}"
    echo -e "${BOLD}============================================================${NC}"
    echo -e "  ${GREEN}Pasos exitosos:${NC}        $STEPS_OK"
    echo -e "  ${YELLOW}Avisos (no críticos):${NC}  $STEPS_WARN"
    echo -e "  ${RED}Fallos:${NC}                 $STEPS_FAIL"
    echo "  Log completo en: $LOG_FILE"
    echo -e "${BOLD}============================================================${NC}"
    echo
    echo "Siguiente paso recomendado (NO reinicies la VM todavía):"
    echo "  1. Cierra sesión desde el menú de XFCE (Logout), NO 'reboot' directo."
    echo "  2. Vuelve a iniciar sesión."
    echo "  3. Si todo carga bien (panel, fondo, bspwm tiling activo), recién"
    echo "     entonces puedes reiniciar la VM completa si lo deseas."
    echo "  4. Si algo se congela de nuevo, vuelve a la TTY (Ctrl+Alt+F2) y"
    echo "     revisa el log: $LOG_FILE"
    echo
}

### ============================ MAIN ======================================== ###

main() {
    log "Iniciando instalación corregida de bspwm para Kali Linux"
    log "Log de esta ejecución: $LOG_FILE"

    preflight_checks
    install_packages
    create_directories
    remove_xfce_hotkeys
    create_bspwmrc
    create_sxhkdrc
    create_compositor_config
    create_rofi_config
    create_autostart_entries
    fix_zsh_history_if_corrupt
    manual_step_xfwm4
    print_summary

    if [[ "$STEPS_FAIL" -gt 0 ]]; then
        warn "El script terminó con algunos fallos. Revisa el log: $LOG_FILE"
        exit 1
    fi
    success "¡Automatización completada!"
}

main "$@"