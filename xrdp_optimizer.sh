#!/usr/bin/env bash
set -euo pipefail

cat <<'BANNER'
 __  __ ____  ____  ____
 \ \/ /|  _ \|  _ \|  _ \
  \  / | |_) | | | | |_) |
  /  \ |  _ <| |_| |  __/
 /_/\_\|_| \_\____/|_|

  ___  ____ _____ ___ __  __ ___ __________ ____
 / _ \|  _ \_   _|_ _|  \/  |_ _|__  / ____|  _ \
| | | | |_) || |  | || |\/| || |  / /|  _| | |_) |
| |_| |  __/ | |  | || |  | || | / /_| |___|  _ <
 \___/|_|    |_| |___|_|  |_|___/____|_____|_| \_\

BANNER


usage() {
  printf 'Uso: sudo bash %s [--ip IPv4 | --interface NOME | --auto]\n' "$0"
}

if (( EUID != 0 )); then
  echo 'Execute com sudo ou como root.' >&2
  exit 1
fi

if ! command -v ip >/dev/null 2>&1; then
  echo 'O comando ip (iproute2) não foi encontrado.' >&2
  exit 1
fi

target=/etc/xrdp/xrdp.ini
if [[ ! -d /etc/xrdp ]]; then
  echo 'Diretório /etc/xrdp não encontrado. Instale o xrdp primeiro.' >&2
  exit 1
fi

declare -a interfaces=() addresses=()
while read -r interface address; do
  [[ -n "$interface" && -n "$address" ]] || continue
  interfaces+=("$interface")
  addresses+=("$address")
done < <(ip -o -4 addr show scope global | awk '{ split($4, a, "/"); sub(/@.*/, "", $2); print $2, a[1] }')

if (( ${#addresses[@]} == 0 )); then
  echo 'Nenhum IPv4 global foi encontrado nas interfaces de rede.' >&2
  exit 1
fi

is_local_address() {
  local candidate=$1 address
  for address in "${addresses[@]}"; do
    [[ "$address" == "$candidate" ]] && return 0
  done
  return 1
}

mode=interactive
value=
if (( $# > 0 )); then
  case "$1" in
    --ip|--interface)
      (( $# == 2 )) || { usage >&2; exit 2; }
      mode=$1
      value=$2
      ;;
    --auto)
      (( $# == 1 )) || { usage >&2; exit 2; }
      mode=auto
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
fi

selected_ip=
case "$mode" in
  --ip)
    selected_ip=$value
    ;;
  --interface)
    for i in "${!interfaces[@]}"; do
      if [[ "${interfaces[i]}" == "$value" ]]; then
        selected_ip=${addresses[i]}
        break
      fi
    done
    [[ -n "$selected_ip" ]] || { echo "Interface sem IPv4 global: $value" >&2; exit 1; }
    ;;
  auto)
    selected_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i=1; i<=NF; i++) if ($i=="src") { print $(i+1); exit } }' || true)
    if [[ -z "$selected_ip" ]] || ! is_local_address "$selected_ip"; then
      selected_ip=${addresses[0]}
    fi
    ;;
  interactive)
    echo 'IPv4 encontrados no servidor:'
    for i in "${!interfaces[@]}"; do
      printf '  %d) %s — %s\n' "$((i + 1))" "${interfaces[i]}" "${addresses[i]}"
    done
    read -r -p 'Escolha o número ou digite um IPv4 da lista [1]: ' answer
    answer=${answer:-1}
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#addresses[@]} )); then
      selected_ip=${addresses[answer-1]}
    else
      selected_ip=$answer
    fi
    ;;
esac

if ! is_local_address "$selected_ip"; then
  echo "O IP $selected_ip não está atribuído a uma interface IPv4 global deste servidor." >&2
  exit 1
fi

tmp=$(mktemp /etc/xrdp/.xrdp.ini.XXXXXX)
trap 'rm -f -- "$tmp"' EXIT
sed "s/__XRDP_BIND_IP__/$selected_ip/g" <<'XRDP_INI' > "$tmp"
; XRDP configuration file. Forked by Kali.

[Globals]
; xrdp.ini file version number
ini_version=1

; fork a new process for each incoming connection
fork=true

; ports to listen on, number alone means listen on all interfaces
; 0.0.0.0 or :: if ipv6 is configured
; space between multiple occurrences
; ALL specified interfaces must be UP when xrdp starts, otherwise xrdp will fail to start
;
; Examples:
;   port=3389
;   port=unix://./tmp/xrdp.socket
;   port=tcp://.:3389                           127.0.0.1:3389
;   port=tcp://:3389                            *:3389
;   port=tcp://<any ipv4 format addr>:3389      192.168.1.1:3389
;   port=tcp6://.:3389                          ::1:3389
;   port=tcp6://:3389                           *:3389
;   port=tcp6://{<any ipv6 format addr>}:3389   {FC00:0:0:0:0:0:0:1}:3389
;   port=vsock://<cid>:<port>
port=tcp://__XRDP_BIND_IP__:3389

; if used inside a Hyper-V VM through vmconnect and bound on vsock,
; turn this on to enable wider security protocol support.
#vmconnect=true

; Unprivileged User name and group to run the xrdp daemon.
; It is HIGHLY RECOMMENDED you set these values. See the xrdp.ini(5)
; manpage for more information on setting and checking these.
runtime_user=xrdp
runtime_group=xrdp

; regulate if the listening socket use socket option tcp_nodelay
; no buffering will be performed in the TCP stack
tcp_nodelay=true

; regulate if the listening socket use socket option keepalive
; if the network connection disappear without close messages the connection will be closed
tcp_keepalive=true

; set tcp send/recv buffer
; These parameters are largely historic. On systems with dynamic TCP
; buffer sizes, setting them manually will either impact performance or
; waste memory
#tcp_send_buffer_bytes=32768
#tcp_recv_buffer_bytes=32768

; security layer can be 'tls', 'rdp' or 'negotiate'
; for client compatible layer
security_layer=negotiate

; minimum security level allowed for client for classic RDP encryption
; use tls_ciphers to configure TLS encryption
; can be 'none', 'low', 'medium', 'high', 'fips'
crypt_level=none

; X.509 certificate and private key
; openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 365
; note this needs the user xrdp to be a member of the ssl-cert group, do with e.g.
;$ sudo adduser xrdp ssl-cert
certificate=
key_file=

; [Debug] Log file for TLS pre-master secrets - see xrdp.ini(5)
#tls_pms_log_file=/tmp/xrdp-pms/premaster.log

; set SSL protocols
; can be comma separated list of 'SSLv3', 'TLSv1', 'TLSv1.1', 'TLSv1.2', 'TLSv1.3'
ssl_protocols=TLSv1.2, TLSv1.3
; set TLS cipher suites
#tls_ciphers=HIGH

; concats the domain name to the user if set for authentication with the separator
; for example when the server is multi homed with SSSd
#domain_user_separator=@

; The following options will override the keyboard layout settings.
; These options are for DEBUG and are not recommended for regular use.
#xrdp.override_keyboard_type=0x04
#xrdp.override_keyboard_subtype=0x01
#xrdp.override_keylayout=0x00000409

; Section name to use for automatic login if the client sends username
; and password. If empty, the domain name sent by the client is used.
; If empty and no domain name is given, the first suitable section in
; this file will be used.
autorun=

allow_channels=true
allow_multimon=false
bitmap_cache=true
bitmap_compression=true
bulk_compression=true
hidelogwindow=true
max_bpp=32
new_cursors=true
; fastpath - can be 'input', 'output', 'both', 'none'
use_fastpath=both
; when true, userid/password *must* be passed on cmd line. If the password
; is incorrect, the login will fail
#require_credentials=true
; when true, the userid will be used to try to authenticate
#enable_token_login=true
; You can set the PAM error text in a gateway setup (MAX 256 chars)
#pamerrortxt=change your password according to policy at http://url

;
; colors used by windows in RGB format
;
black=555555
grey=ffffff
dark_grey=ffffff
blue=19315a
dark_blue=2777ff
white=eeeeee
#red=ff0000
#green=00ff00
#background=626c72

;
; Select a default fv1 font
;
; This parameter is a comma-separated list of DPI:name pairs.
; The list is scanned from left-to-right. The font used is the first
; font whose DPI value is less-than-or-equal to the vertical DPI of
; the monitor used for the login screen.
#fv1_select=130:sans-18.fv1,0:sans-10.fv1
; Default DPI used for a monitor when that information is unknown
#default_dpi=96

;
; configure login screen
;

; Login Screen Window Title
#ls_title=My Login Title

; top level window background color in RGB format
ls_top_window_bg_color=2b62c0

; width and height of login screen
;
; When the sans-10.fv1 font is selected, these values are in pixels.
; For other fonts, these values (and other size values) will be scaled
; appropriately to preserve the proportions of the login screen.
;
; The default height allows for about 5 fields to be comfortably displayed
; above the buttons at the bottom. To display more fields, make <ls_height>
; larger, and also increase <ls_btn_ok_y_pos> and <ls_btn_cancel_y_pos>
; below
;
ls_width=350
ls_height=370

; login screen background color in RGB format
ls_bg_color=ffffff

; optional background image filename. BMP format is always supported,
; but other formats will be supported if xrdp is build with imlib2
; The transform can be one of the following:-
;     none  : No transformation. Image is placed in bottom-right corner
;             of the screen.
;     scale : Image is scaled to the screen size. The image aspect
;             ratio is not preserved.
;     zoom  : Image is scaled to the screen size. The image aspect
;             ratio is preserved by clipping the image.
#ls_background_image=
#ls_background_transform=none

; logo
; full path to file or file in shared folder. BMP format is always supported,
; but other formats will be supported if xrdp is build with imlib2
; For transform values, see 'ls_background_transform'. The logo width and
; logo height are ignored for a transform of 'none'.
ls_logo_filename=/usr/share/xrdp/kali.bmp
ls_logo_transform=none
ls_logo_width=250
ls_logo_height=110
ls_logo_x_pos=0
ls_logo_y_pos=0

; for positioning labels such as username, password etc
ls_label_x_pos=30
ls_label_width=65

; for positioning text and combo boxes next to above labels
ls_input_x_pos=110
ls_input_width=210

; y pos for first label and combo box
ls_input_y_pos=240

; OK button
ls_btn_ok_x_pos=142
ls_btn_ok_y_pos=325
ls_btn_ok_width=85
ls_btn_ok_height=30

; Cancel button
ls_btn_cancel_x_pos=237
ls_btn_cancel_y_pos=325
ls_btn_cancel_width=85
ls_btn_cancel_height=30

[Logging]
; Note: Log levels can be any of: core, error, warning, info, debug, or trace
LogFile=xrdp.log
LogLevel=INFO
EnableSyslog=true
#SyslogLevel=INFO
#EnableConsole=false
#ConsoleLevel=INFO
#EnableProcessId=false

[LoggingPerLogger]
; Note: per logger configuration is only used if xrdp is built with
; --enable-devel-logging
#xrdp.c=INFO
#main()=INFO

[Channels]
; Channel names not listed here will be blocked by XRDP.
; You can block any channel by setting its value to false.
; IMPORTANT! All channels are not supported in all use
; cases even if you set all values to true.
; You can override these settings on each session type
; These settings are only used if allow_channels=true
rdpdr=true
rdpsnd=false
drdynvc=true
cliprdr=true
rail=false
xrdpvr=false

; for debugging xrdp, in section xrdp1, change port=-1 to this:
#port=/tmp/.xrdp/xrdp_display_10


;
; Session types
;

; Some session types such as Xorg and Xvnc start a display server.
; Startup command-line parameters for the display server are configured
; in sesman.ini. See and configure also sesman.ini.
[Xorg]
name=Xorg
lib=libxup.so
username=ask
password=ask
port=-1
code=20
; Frame capture interval (milliseconds)
h264_frame_interval=16
rfx_frame_interval=16
normal_frame_interval=16

[Xvnc]
name=Xvnc
lib=libvnc.so
username=ask
password=ask
ip=127.0.0.1
; port is -1 (sesman controlled), numeric (TCP connection) or an
; absolute path (UDS connection).
port=-1
; For sesman-controlled Xvnc, the 'code' parameter can be used to switch
; the connection protocol:-
; 0 - Use a TCP connection
; 1 - Use a Unix Domain Sockets (UDS) connection
;     UDS connections are not supported by older VNC servers, but are
;     supported by TigerVNC. If you select this option, comment out
;     (or remove) the 'ip=' setting.
;
; UDS connections are recommended, if your X server supports them. They are
; more secure, and untroubled by firewalls.
;
; On FIPS-based systems, TCP CANNOT be used, as the classic algorithm used for
; VNC password files is no longer considered secure by FIPS
;
; The default value is 0 on non-FIPS systems, and 1 on FIPS-based systems.
#code=0
#xserverbpp=24
#delay_ms=2000
; Disable requested encodings to support buggy VNC servers
; (1 = ExtendedDesktopSize)
#disabled_encodings_mask=0

; Generic VNC Proxy
; Tailor this to specific hosts and VNC instances by specifying an ip
; and port and setting a suitable name.
[vnc-any]
name=vnc-any
lib=libvnc.so
ip=ask
port=ask5900
username=na
password=ask
#pamusername=asksame
#pampassword=asksame
#delay_ms=2000
; Use one of these to connect to a chansrv instance created outside of sesman
; (e.g. as part of an x11vnc console session). Replace 'n' with the
; display number of the session, and (if applicable) 'u' with the numeric
; UID of the session.
;
; If 'username' or 'pamusername' is set, you probably don't need to use
; the two parameter variant with 'u'.
#chansrvport=DISPLAY(n)
#chansrvport=DISPLAY(n,u)

; Generic RDP proxy using NeutrinoRDP
; Tailor this to specific hosts by specifying an ip and port and setting
; a suitable name.
[neutrinordp-any]
name=neutrinordp-any
; To use this section, you should build xrdp with configure option
; --enable-neutrinordp.
lib=libxrdpneutrinordp.so
ip=ask
port=ask3389
username=ask
password=ask
; Uncomment the following lines to enable PAM authentication for proxy
; connections.
#pamusername=ask
#pampassword=ask
; Currently NeutrinoRDP doesn't support dynamic resizing. Uncomment
; this line if you're using a client which does.
#enable_dynamic_resizing=false
; By default, performance settings requested by the RDP client are ignored
; and chosen by NeutrinoRDP. Uncomment this line to allow the user to
; select performance settings in the RDP client.
#perf.allow_client_experiencesettings=true
; Override any experience setting by uncommenting one or more of the
; following lines.
#perf.wallpaper=false
#perf.font_smoothing=false
#perf.desktop_composition=false
#perf.full_window_drag=false
#perf.menu_anims=false
#perf.themes=false
#perf.cursor_blink=false
; By default NeutrinoRDP supports cursor shadows. If this is giving
; you problems (e.g. cursor is a black rectangle) try disabling cursor
; shadows by uncommenting the following line.
#perf.cursor_shadow=false
; By default, NeutrinoRDP uses the keyboard layout of the remote RDP Server.
; If you want to tell the remote the keyboard layout of the RDP Client,
; by uncommenting the following line.
#neutrinordp.allow_client_keyboardLayout=true
; The following options will override the remote keyboard layout settings.
; These options are for DEBUG and are not recommended for regular use.
#neutrinordp.override_keyboardLayout_mask=0x0000FFFF
#neutrinordp.override_kbd_type=0x04
#neutrinordp.override_kbd_subtype=0x01
#neutrinordp.override_kbd_fn_keys=12
#neutrinordp.override_kbd_layout=0x00000409

; You can override the common channel settings for each session type
#channel.rdpdr=true
#channel.rdpsnd=true
#channel.drdynvc=true
channel.cliprdr=true
#channel.rail=true
#channel.xrdpvr=true
XRDP_INI

if [[ -e "$target" ]]; then
  backup="${target}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p -- "$target" "$backup"
  echo "Backup: $backup"
fi
install -m 0644 -- "$tmp" "$target"
echo "Configuração gravada em $target (IP $selected_ip, porta 3389)."
echo 'Para aplicar: sudo systemctl restart xrdp'
