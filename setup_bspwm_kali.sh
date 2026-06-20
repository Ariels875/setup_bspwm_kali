#!/usr/bin/env bash
###############################################################################
#
#  setup_bspwm_kali.sh
#  ---------------------------------------------------------------------------
#  Automatiza la instalación y configuración de bspwm + sxhkd + compositor
#  (picom/compton) + rofi corriendo encima de una sesión XFCE en Kali Linux.
#
#  Basado en la guía: https://bgdawes.github.io/bspwm-xfce-dotfiles/
#  Corregido y endurecido a partir de los problemas reales encontrados:
#    - Permisos rotos por "sudo mkdir" en carpetas de usuario
#    - Ruta inválida "echo($USER)" al lanzar el compositor
#    - Atajo de teclado duplicado (alt+Return) en sxhkdrc
#    - Regla de bspwm que ocultaba el panel de XFCE (xfce4-panel)
#    - Falta de top_padding para reservar espacio al panel
#    - Falta de manejo de errores en cada paso
#
#  Uso:
#    chmod +x setup_bspwm_kali.sh
#    ./setup_bspwm_kali.sh
#
#  NO ejecutar como root ni con sudo directamente. El script pedirá la
#  contraseña de sudo solo cuando sea necesario (instalación de paquetes).
#
###############################################################################

set -uo pipefail

### ============================ CONFIGURACIÓN ============================ ###

LOG_FILE="$HOME/bspwm_setup_$(date +%Y%m%d_%H%M%S).log"
TOP_PADDING=28                # Ajusta si tu panel de XFCE tiene otra altura
COMPOSITOR=""                 # Se autodetecta: "picom" o "compton"
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
    err "El script se detuvo. Revisa el log completo en: $LOG_FILE"
    exit 1
}

# Ejecuta un comando crítico: si falla, el script se detiene por completo.
run_critical() {
    local desc="$1"; shift
    log "Ejecutando: $desc"
    if "$@" >> "$LOG_FILE" 2>&1; then
        success "$desc"
    else
        die "Falló (paso crítico): $desc  ->  comando: $*"
    fi
}

# Ejecuta un comando opcional: si falla, solo se avisa y se continúa.
run_optional() {
    local desc="$1"; shift
    log "Ejecutando (opcional): $desc"
    if "$@" >> "$LOG_FILE" 2>&1; then
        success "$desc"
    else
        warn "Falló (no crítico, se continúa): $desc  ->  comando: $*"
    fi
}

# Hace un respaldo con timestamp si el archivo ya existe.
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

    if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
        die "La variable \$HOME no está definida correctamente."
    fi

    log "Verificando acceso a sudo (puede pedir tu contraseña)..."
    if ! sudo -v; then
        die "Se requieren privilegios sudo para instalar paquetes. Abortando."
    fi
    success "Acceso sudo confirmado"

    log "Verificando conexión a internet / repositorios..."
    if ! sudo apt-get update -qq >> "$LOG_FILE" 2>&1; then
        die "No se pudo ejecutar 'apt update'. Revisa tu conexión o tus repositorios."
    fi
    success "Repositorios actualizados correctamente"
}

### ============================ INSTALACIÓN DE PAQUETES =================== ###

install_packages() {
    log "=== Instalando paquetes base ==="
    run_critical "Instalar bspwm, sxhkd, rofi, xterm, wmctrl" \
        sudo apt-get install -y bspwm sxhkd rofi xterm wmctrl

    log "=== Detectando/instalando compositor (picom o compton) ==="
    if command -v picom &>/dev/null; then
        COMPOSITOR="picom"
        success "picom ya está instalado, se usará picom"
    elif command -v compton &>/dev/null; then
        COMPOSITOR="compton"
        success "compton ya está instalado, se usará compton"
    elif apt-cache show picom &>/dev/null; then
        run_critical "Instalar picom" sudo apt-get install -y picom
        COMPOSITOR="picom"
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
    log "=== Creando directorios de configuración ==="
    # IMPORTANTE: sin sudo. Estas carpetas son del usuario, no de root.
    for dir in \
        "$HOME/.config/bspwm" \
        "$HOME/.config/sxhkd" \
        "$HOME/.config/$COMPOSITOR" \
        "$HOME/.config/rofi" \
        "$HOME/.config/autostart"
    do
        if mkdir -p "$dir"; then
            success "Directorio listo: $dir"
        else
            die "No se pudo crear el directorio: $dir"
        fi
    done
}

### ============================ XFCE: QUITAR ATAJOS ======================== ###

remove_xfce_hotkeys() {
    log "=== Eliminando atajos de teclado personalizados de XFCE ==="
    # Si la propiedad no existe (primera vez), xfconf-query devuelve error.
    # Por eso usamos run_optional: no es un fallo real, simplemente no había nada que borrar.
    run_optional "Quitar /commands/custom" \
        xfconf-query -c xfce4-keyboard-shortcuts -p /commands/custom -r -R
    run_optional "Quitar /xfwm4/custom" \
        xfconf-query -c xfce4-keyboard-shortcuts -p /xfwm4/custom -r -R
}

### ============================ ARCHIVOS DE CONFIG ========================= ###

create_bspwmrc() {
    log "=== Creando ~/.config/bspwm/bspwmrc ==="
    local target="$HOME/.config/bspwm/bspwmrc"
    backup_if_exists "$target"

    cat > "$target" << EOF
#! /bin/sh

# --- Monitors & Desktops ---
bspc monitor -d I II III IV V VI VII VIII IX X

# --- Global settings ---
bspc config border_width         2
bspc config window_gap           12
bspc config split_ratio          0.52
bspc config borderless_monocle   true
bspc config gapless_monocle      true

# Espacio reservado arriba para que el panel de XFCE sea visible
bspc config top_padding ${TOP_PADDING}

# --- Mouse settings ---
bspc config pointer_modifier mod1
bspc config pointer_action1 resize_side
bspc config pointer_action2 resize_corner
bspc config pointer_action3 move

# --- Rules ---
bspc rule -a Gimp desktop='^8' state=floating follow=on
bspc rule -a Chromium desktop='^2'
bspc rule -a mplayer2 state=floating
bspc rule -a Kupfer.py focus=on
bspc rule -a Screenkey manage=off

# IMPORTANTE: NO usar manage=off para el panel, porque eso le impide
# dibujarse correctamente. Se deja como ventana flotante, siempre encima,
# sin borde y sin robar el foco.
bspc rule -a xfce4-panel state=floating layer=above border=off focus=off

# Si usas Docky (opcional):
# bspc rule -a Docky layer=above manage=on border=off focus=off locked=on
EOF

    if [[ $? -ne 0 ]]; then
        die "No se pudo escribir el archivo bspwmrc"
    fi
    success "bspwmrc creado"

    if chmod +x "$target"; then
        success "bspwmrc marcado como ejecutable (chmod +x)"
    else
        die "No se pudo dar permisos de ejecución a bspwmrc"
    fi
}

create_sxhkdrc() {
    log "=== Creando ~/.config/sxhkd/sxhkdrc ==="
    local target="$HOME/.config/sxhkd/sxhkdrc"
    backup_if_exists "$target"

    # NOTA: se corrigió el conflicto de atajo duplicado del .txt original
    # (alt + Return estaba asignado dos veces: a xterm y a rofi).
    # Ahora: alt+Return = terminal, alt+d = rofi (launcher), alt+Tab = rofi (switcher)
    cat > "$target" << 'EOF'
# --- Terminal ---
alt + Return
    xterm

# --- Recargar configuración de sxhkd ---
alt + Escape
    pkill -USR1 -x sxhkd

# --- Cerrar ventana ---
alt + shift + q
    bspc node -c

# --- Rofi: lanzar aplicaciones (antes chocaba con alt+Return, ahora es alt+d) ---
alt + d
    rofi -show run

# --- Rofi: cambiar ventanas ---
alt + Tab
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
alt + {Left,Right}
    bspc desktop -f {prev.local,next.local}

# --- Navegar entre ventanas ---
alt + {Up,Down}
    bspc node -f {next,prev}.local

# --- Mover ventana a otro desktop ---
alt + shift + {1-9,0}
    bspc node -d '^{1-9,10}'

# --- Ir a desktop por número ---
alt + {1-9,0}
    bspc desktop -f '^{1-9,10}'
EOF

    if [[ $? -ne 0 ]]; then
        die "No se pudo escribir el archivo sxhkdrc"
    fi
    success "sxhkdrc creado (con el atajo duplicado corregido)"
}

create_compositor_config() {
    log "=== Creando configuración de ${COMPOSITOR} ==="
    local target="$HOME/.config/${COMPOSITOR}/${COMPOSITOR}.conf"
    backup_if_exists "$target"

    cat > "$target" << 'EOF'
#################################
#
# Backend
#
#################################

backend = "glx";
glx-no-stencil = true;
glx-copy-from-front = false;

#################################
#
# Shadows
#
#################################

shadow = true;
no-dnd-shadow = true;
no-dock-shadow = true;
clear-shadow = true;
shadow-radius = 7;
shadow-offset-x = -7;
shadow-offset-y = -7;
shadow-opacity = 0.7;
shadow-exclude = [
    "name = 'Notification'",
    "class_g = 'Conky'",
    "class_g ?= 'Notify-osd'",
    "class_g = 'Cairo-clock'",
    "_GTK_FRAME_EXTENTS@:c"
];
shadow-ignore-shaped = true;

#################################
#
# Opacity
#
#################################

menu-opacity = 1;
inactive-window-opacity = 1;
inactive-opacity = 0.60;
active-opacity = 1;
frame-opacity = 1;
inactive-opacity-override = false;
alpha-step = 0.06;
blur-background = false;
blur-background-dynamic = false;

mark-wmwin-focused = false;
mark-ovredir-focused = false;
detect-rounded-corners = true;
detect-client-opacity = true;

# Para que rofi no quede transparente cuando está enfocado:
focus-exclude = [ "name = 'rofi'" ];

#################################
#
# Fading
#
#################################

fading = true;
fade-delta = 4;
fade-in-step = 0.03;
fade-out-step = 0.03;
no-fading-openclose = false;

#################################
#
# Other
#
#################################

detect-transient = true;
detect-client-leader = true;
invert-color-include = [ ];
EOF

    if [[ $? -ne 0 ]]; then
        die "No se pudo escribir el archivo de configuración de ${COMPOSITOR}"
    fi
    success "${COMPOSITOR}.conf creado"
}

create_rofi_config() {
    log "=== Creando ~/.config/rofi/config ==="
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
        die "No se pudo escribir el archivo de configuración de rofi"
    fi
    success "Configuración de rofi creada"
    warn "Nota: rofi moderno usa temas .rasi. Esta config antigua puede ser ignorada parcialmente por versiones nuevas de rofi. Si quieres un theme moderno, dime y te genero uno en .rasi."
}

### ============================ AUTOSTART (.desktop) ======================= ###

create_autostart_entries() {
    log "=== Creando entradas de autostart ==="
    local autostart_dir="$HOME/.config/autostart"

    # bspwm
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

    # sxhkd
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

    # Compositor (picom o compton) - se usa la ruta ABSOLUTA real, ya resuelta,
    # porque los archivos .desktop NO expanden variables como $HOME en el campo Exec.
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

    log "Nota: xfce4-panel ya se autoinicia con la sesión XFCE de forma nativa, no necesita una entrada nueva. El problema anterior era la regla de bspwm, no el autostart del panel."
}

### ============================ FIX DEFENSIVO: ZSH HISTORY ================= ###

fix_zsh_history_if_corrupt() {
    log "=== Verificando integridad del historial de zsh ==="
    local hist="$HOME/.zsh_history"

    if [[ ! -f "$hist" ]]; then
        log "No existe ~/.zsh_history todavía, nada que revisar."
        return
    fi

    if command -v zsh &>/dev/null; then
        if zsh -i -c 'true' 2>&1 | grep -qi "corrupt history"; then
            warn "Historial de zsh corrupto detectado"
            local backup="${hist}.bak.$(date +%Y%m%d_%H%M%S)"
            if mv "$hist" "$backup" && touch "$hist"; then
                success "Historial corrupto respaldado en '$backup' y reiniciado"
            else
                warn "No se pudo reparar automáticamente el historial de zsh. Repáralo manualmente con: mv ~/.zsh_history ~/.zsh_history.bak && touch ~/.zsh_history"
            fi
        else
            success "El historial de zsh está en buen estado"
        fi
    else
        log "zsh no está instalado en este sistema, se omite esta verificación."
    fi
}

### ============================ PASO MANUAL: DESACTIVAR XFWM4 ============== ###

manual_step_xfwm4() {
    echo
    echo -e "${YELLOW}${BOLD}============================================================${NC}"
    echo -e "${YELLOW}${BOLD}  PASO MANUAL OBLIGATORIO (no se puede automatizar de forma  ${NC}"
    echo -e "${YELLOW}${BOLD}  100% confiable porque depende del nombre de tu sesión XFCE)${NC}"
    echo -e "${YELLOW}${BOLD}============================================================${NC}"
    echo "Para que bspwm controle las ventanas en vez de xfwm4:"
    echo "  1. Abre: Settings Manager -> Session and Startup"
    echo "  2. Ve a la pestaña 'Session'"
    echo "  3. Busca 'xfwm4' en la lista"
    echo "  4. Cambia su modo de inicio a 'Never'"
    echo "  5. Click en 'Save Session'"
    echo
    echo "También recuerda (si no lo has hecho ya):"
    echo "  Settings Manager -> Keyboard -> Application Shortcuts -> eliminar TODOS"
    echo "  (el script ya intentó esto automáticamente vía xfconf-query, pero"
    echo "   conviene que lo verifiques visualmente)"
    echo

    # Intento "best effort" adicional, basado en tu archivo original.
    # No garantizado: depende de la sesión activa. Si falla, no es crítico.
    run_optional "Intento best-effort de registrar bspwm en sesión Failsafe" \
        xfconf-query -c xfce4-session -p /sessions/Failsafe/Client0_Command \
        --create -t string -s "bspwm"

    read -rp "Presiona ENTER cuando hayas completado el paso manual de arriba para continuar... "
}

### ============================ APLICAR CAMBIOS EN VIVO ==================== ###

apply_live_reload() {
    log "=== Aplicando cambios en la sesión actual (mejor esfuerzo) ==="

    if pgrep -x bspwm &>/dev/null; then
        run_optional "Recargar configuración de bspwm" bspc wm -r
    else
        log "bspwm no está corriendo todavía en esta sesión (normal si es la primera instalación). Se aplicará al reiniciar sesión."
    fi

    if pgrep -x sxhkd &>/dev/null; then
        run_optional "Recargar sxhkd" pkill -USR1 -x sxhkd
    else
        log "sxhkd no está corriendo, se iniciará con el próximo login (o ejecútalo manualmente con: sxhkd &)"
    fi

    if pgrep -x "$COMPOSITOR" &>/dev/null; then
        run_optional "Reiniciar ${COMPOSITOR}" pkill -x "$COMPOSITOR"
        sleep 1
    fi
    local conf_path="${HOME}/.config/${COMPOSITOR}/${COMPOSITOR}.conf"
    nohup "$COMPOSITOR" --config "$conf_path" -b >> "$LOG_FILE" 2>&1 &
    disown
    success "${COMPOSITOR} relanzado en segundo plano"

    # Reiniciar el panel para que tome la nueva regla de bspwm (las reglas
    # solo se aplican a ventanas nuevas, no a las ya existentes).
    if pgrep -x xfce4-panel &>/dev/null; then
        run_optional "Reiniciar xfce4-panel para aplicar la nueva regla de bspwm" \
            pkill -x xfce4-panel
        sleep 1
        nohup xfce4-panel >> "$LOG_FILE" 2>&1 &
        disown
        success "xfce4-panel relanzado"
    fi
}

### ============================ RESUMEN FINAL =============================== ###

print_summary() {
    echo
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${BOLD}                     RESUMEN DE EJECUCIÓN                    ${NC}"
    echo -e "${BOLD}============================================================${NC}"
    echo -e "  ${GREEN}Pasos exitosos:${NC}   $STEPS_OK"
    echo -e "  ${YELLOW}Avisos (no críticos):${NC} $STEPS_WARN"
    echo -e "  ${RED}Fallos:${NC}            $STEPS_FAIL"
    echo "  Log completo en: $LOG_FILE"
    echo -e "${BOLD}============================================================${NC}"
    echo
    echo "Recomendación final: cierra sesión y vuelve a entrar (logout/login)"
    echo "para que todos los componentes arranquen limpios desde cero."
    echo
}

### ============================ MAIN ======================================== ###

main() {
    log "Iniciando automatización de bspwm + XFCE en Kali Linux"
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
    apply_live_reload
    print_summary

    if [[ "$STEPS_FAIL" -gt 0 ]]; then
        warn "El script terminó con algunos fallos. Revisa el log: $LOG_FILE"
        exit 1
    fi

    success "¡Automatización completada!"
}

main "$@"
