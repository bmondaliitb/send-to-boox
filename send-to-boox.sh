#!/usr/bin/env bash
set -euo pipefail

message() {
    local kind=$1 text=$2
    text=${text//\\n/$'\n'}
    if command -v zenity >/dev/null && zenity "--$kind" --no-markup --title='Send to BOOX' --text="$text" 2>/dev/null; then
        return
    fi
    notify-send --app-name='Send to BOOX' 'Send to BOOX' "$text" 2>/dev/null || printf '%s\n' "$text" >&2
}
fail() { message error "$1"; exit 1; }

for command in adb file zenity; do
    command -v "$command" >/dev/null || fail "Missing $command. Please run the installation instructions again."
done

config=${XDG_CONFIG_HOME:-$HOME/.config}/send-to-boox/wireless

# Dropped files/URLs go straight through; opening the icon exposes all actions.
if (( $# == 0 )); then
    action=$(zenity --list --title='Send to BOOX' --text='What would you like to do?' \
        --column=Action --column=Description --hide-column=1 --print-column=1 \
        pdf 'Send a PDF' link 'Send a webpage' \
        setup-wireless 'Set up / connect wireless') || exit 0
    [[ -n $action ]] || exit 0
    set -- "--$action"
fi

wireless_tools() {
    command -v nmcli >/dev/null && command -v timeout >/dev/null ||
        fail 'Wireless mode needs NetworkManager (nmcli) and timeout.'
}

# All setup failures return to a choice or retry screen; Cancel leaves settings intact.
choose() {
    local text=$1
    text=${text//\\n/$'\n'}
    zenity --list --no-markup --width=650 --height=360 --title='Connect to BOOX' --text="$text" \
        --column=Action --column='Next step' --hide-column=1 --print-column=1 "${@:2}"
}
notice() {
    local text=$1
    text=${text//\\n/$'\n'}
    zenity --info --no-markup --width=620 --title='Connect to BOOX' --text="$text"
}
# Keep long ADB operations visible without putting codes in process arguments.
progress_run() {
    local label=$1 temporary result
    shift
    temporary=$(mktemp -d) || return 1
    {
        printf '# %s\n' "$label"
        if "$@" > "$temporary/output" 2>&1; then result=0; else result=$?; fi
        printf '%s' "$result" > "$temporary/status"
        printf '100\n'
    } | zenity --progress --pulsate --auto-close --no-cancel --width=500 \
        --title='Connect to BOOX' --text="$label" >/dev/null 2>&1 || true
    cat "$temporary/output"
    result=$(cat "$temporary/status")
    rm -rf -- "$temporary"
    return "$result"
}
valid_endpoint() {
    local value=$1 host port part
    [[ $value =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] || return 1
    host=${value%:*} port=${value##*:}
    (( 10#$port > 0 && 10#$port <= 65535 )) || return 1
    local -a parts
    IFS=. read -r -a parts <<< "$host"
    for part in "${parts[@]}"; do (( 10#$part <= 255 )) || return 1; done
}
try_wireless() {
    local attempt state
    for attempt in 1 2 3; do
        connection_error=$(progress_run "Connecting to $endpoint…" timeout 5 adb connect "$endpoint") || true
        if state=$(timeout 5 adb -s "$endpoint" get-state 2>&1) && [[ $state == device ]]; then return 0; fi
    done
    connection_error+=$'\n'"$state"
    return 1
}
save_connection() {
    local temporary
    mkdir -p -- "${config%/*}" || return 1
    temporary=$(mktemp "${config}.XXXXXX") || return 1
    if ! printf '%s\n' "$network" "$endpoint" "$identity" > "$temporary" ||
        ! mv -- "$temporary" "$config"; then
        rm -f -- "$temporary"
        return 1
    fi
}

# Called only on the saved network. Never trust a discovered address without
# checking the remembered device serial through an authorized ADB connection.
restore_connection() {
    local original=$endpoint candidate service kind extra actual state
    local -a candidates=("$endpoint")
    local -A seen=()
    [[ -n $identity ]] || return 1
    timeout 5 adb start-server >/dev/null 2>&1 || true
    while read -r service kind candidate extra; do
        [[ $kind == _adb-tls-connect._tcp || $kind == _adb-tls-connect._tcp. ]] || continue
        valid_endpoint "$candidate" && candidates+=("$candidate")
    done < <(timeout 8 adb mdns services 2>/dev/null)
    # Auto-connected devices may appear before discovery output is populated.
    while read -r candidate state extra; do
        [[ $state == device ]] || continue
        valid_endpoint "$candidate" && candidates+=("$candidate")
    done < <(timeout 5 adb devices 2>/dev/null)
    for candidate in "${candidates[@]}"; do
        valid_endpoint "$candidate" || continue
        [[ -z ${seen[$candidate]:-} ]] || continue
        seen[$candidate]=1
        timeout 5 adb connect "$candidate" >/dev/null 2>&1 || continue
        [[ $(timeout 5 adb -s "$candidate" get-state 2>/dev/null) == device ]] || continue
        actual=$(timeout 5 adb -s "$candidate" shell getprop ro.serialno 2>/dev/null) || continue
        [[ ${actual//$'\r'/} == "$identity" ]] || continue
        endpoint=$candidate
        if [[ $endpoint != "$original" ]]; then
            save_connection || { endpoint=$original; return 1; }
        fi
        return 0
    done
    return 1
}

setup_wireless() {
    wireless_tools
    local -a saved=() networks=()
    local network='' network_name uuid type name i mode answer ip address output identity temporary pairing code
    local suggested='' endpoint=''
    [[ ! -f $config ]] || mapfile -t saved < "$config"
    while :; do
        networks=()
        while IFS=: read -r uuid type name; do
            case $type in 802-11-wireless|802-3-ethernet) networks+=("$uuid" "$name");; esac
        done < <(nmcli --escape no -t -f UUID,TYPE,NAME connection show --active)
        (( ${#networks[@]} )) && break
        notice 'Step 1 — Connect your computer to home Wi-Fi or Ethernet. Connect BOOX to the same network. Click OK to check again, or close this window to stop.' || return 1
    done
    network=$(choose 'Step 1 — Connect BOOX to the same trusted home network. Select the computer connection to use:' "${networks[@]}") || return 1
    [[ -n $network ]] || return 1
    network_name=$network
    for ((i=0; i<${#networks[@]}; i+=2)); do
        [[ ${networks[i]} != "$network" ]] || network_name=${networks[i+1]}
    done
    suggested=${saved[1]:-}
    while :; do
        mode=$(choose "Step 2 — Choose how to connect on $network_name." \
            reconnect 'Reconnect an existing wireless connection' \
            pair 'Pair using BOOX Wireless debugging (no USB required)' \
            usb 'Set up wireless using a USB cable' \
            help 'I cannot find Wireless debugging / Developer options') || return 1
        [[ -n $mode ]] || return 1
        if [[ $mode == reconnect && ${saved[0]:-} == "$network" && -n ${saved[2]:-} ]]; then
            endpoint=${saved[1]} identity=${saved[2]}
            if restore_connection; then
                notice "Reconnected to your remembered BOOX at $endpoint. Its identity has been verified. You can send files now." || true
                return 0
            fi
        fi
        if [[ $mode == help ]]; then
            answer=$(choose 'On BOOX, USB Debug Mode is usually in Apps → menu → App Management. Full Android Developer options may be hidden.\n\nIf Developer options says “please enable first”, open Android About device and tap Build number seven times. Then open Developer options again. Firmware menus vary.\n\nConnect and authorize USB to open those screens from here.' \
                about 'Open Android About device on BOOX' developer 'Open Developer options on BOOX' back 'Back to connection methods') || return 1
            case $answer in
                about|developer)
                    if [[ $(timeout 5 adb -d get-state 2>/dev/null) != device ]]; then
                        notice 'USB is not ready. Connect a data-capable USB cable, unlock BOOX, enable USB Debug Mode, and accept “Allow USB debugging”. Then try this help step again.' || return 1
                        continue
                    fi
                    address=android.settings.DEVICE_INFO_SETTINGS
                    [[ $answer != developer ]] || address=android.settings.APPLICATION_DEVELOPMENT_SETTINGS
                    output=$(timeout 10 adb -d shell am start -a "$address" 2>&1) || true
                    notice "Check the BOOX screen. If Wireless debugging is absent from Developer options, use USB setup instead.\n\n$output" || return 1
                    ;;
            esac
            continue
        fi
        if [[ $mode == usb ]]; then
            while [[ $(timeout 5 adb -d get-state 2>/dev/null) != device ]]; do
                answer=$(choose 'Step 3 — Connect USB and unlock BOOX.\n\n1. Use a cable that supports data.\n2. Enable USB Debug Mode in BOOX App Management.\n3. Accept “Allow USB debugging” on BOOX.\n4. Keep only one Android device connected.\n\nIf nothing appears, try another cable or USB port.' retry 'USB is connected — check again' back 'Choose another method') || return 1
                [[ $answer == retry ]] || break
            done
            [[ $(timeout 5 adb -d get-state 2>/dev/null) == device ]] || continue
            address=$(timeout 5 adb -d shell ip -o -4 addr show wlan0 2>/dev/null) || address=''
            if [[ $address =~ inet[[:space:]]+([0-9.]+)/ ]]; then suggested=${BASH_REMATCH[1]}:5555; fi
            if ! output=$(progress_run 'Enabling wireless access over USB…' timeout 15 adb -d tcpip 5555); then
                notice "Could not enable wireless access. Keep USB connected, check authorization, then retry USB setup.\n\n$output" || return 1
                continue
            fi
        elif [[ $mode == pair ]]; then
            notice 'Step 3 — On BOOX, open Developer options → Wireless debugging and enable it. Allow your home network.\n\nTap “Pair device with pairing code” and leave that screen open. If you cannot find it, cancel and choose the help option or USB setup.\n\nPairing is remembered, but after reboot you may need to enable Wireless debugging again. Its connection port can change.' || return 1
            pairing=$(zenity --entry --width=620 --title='Pair BOOX' --text='Enter the IP address and pairing port shown in the pairing-code window (for example 192.168.0.10:37001):') || continue
            if ! valid_endpoint "$pairing"; then notice 'Enter an IPv4 address followed by : and a port between 1 and 65535.' || return 1; continue; fi
            code=$(zenity --entry --hide-text --title='Pair BOOX' --text='Enter the six-digit pairing code shown on BOOX:') || continue
            if [[ ! $code =~ ^[0-9]{6}$ ]]; then notice 'The pairing code must contain six digits. Open a fresh pairing-code window and try again.' || return 1; continue; fi
            if ! output=$(printf '%s\n' "$code" | progress_run 'Pairing with BOOX…' timeout 30 adb pair "$pairing") || [[ $output != *'Successfully paired'* ]]; then
                unset code
                notice 'Pairing did not succeed. Make sure both devices use the same network, reopen “Pair device with pairing code” for a fresh code and port, then try again. If adb does not support pairing, update Android platform-tools or use USB setup.' || return 1
                continue
            fi
            unset code
            suggested=${pairing%:*}:
        fi
        while :; do
            if [[ $mode == usb ]]; then
                ip=$(zenity --entry --width=620 --title='Step 4 — BOOX Wi-Fi address' --entry-text="${suggested%:*}" --text='Confirm BOOX’s Wi-Fi IP address. Find it in BOOX Wi-Fi settings. Keep USB connected until setup succeeds:') || break
                endpoint=$ip:5555
            else
                endpoint=$(zenity --entry --no-markup --width=650 --title='Step 4 — Connect wirelessly' --entry-text="$suggested" --text=$'Enter BOOX’s IP address and CONNECTION port.\n\nFor Wireless debugging: use “IP address & Port” on its main screen, not the pairing-code window. The port may change after reboot.\n\nFor previous USB setup: use IP:5555 (for example 192.168.0.10:5555).') || break
            fi
            if ! valid_endpoint "$endpoint"; then notice 'Use an IPv4 address and a port between 1 and 65535. Check the numbers and try again.' || return 1; continue; fi
            suggested=$endpoint
            if try_wireless; then
                identity=$(timeout 10 adb -s "$endpoint" shell getprop ro.serialno) || identity=''
                identity=${identity//$'\r'/}
                if [[ -z $identity || $identity == *$'\n'* ]]; then
                    notice 'BOOX connected, but its identity could not be checked. Unlock it, accept any debugging prompt, and retry.' || return 1
                    continue
                fi
                save_connection || { notice 'Could not save connection settings. Check available disk space and try again.'; return 1; }
                notice 'Connected and verified. You can unplug USB and send PDFs or webpages.\n\nIf you used USB setup, a BOOX reboot may require USB setup again. If you paired wirelessly, enable Wireless debugging after reboot. This app remembers your BOOX and looks for its new address and port automatically on this network.' || true
                return 0
            fi
            answer=$(choose "Could not connect to $endpoint.\n\n1. Wake and unlock BOOX; confirm both devices are on the same Wi-Fi.\n2. For paired debugging, enable Wireless debugging and check its current connection port.\n3. For port 5555 after reboot, choose USB setup to enable it again.\n\nDetails: $connection_error" retry 'Check / correct address and retry' back 'Choose another connection method') || return 1
            [[ $answer == retry ]] || break
        done
    done
}

if [[ ${1:-} == --setup-wireless ]]; then
    setup_wireless || exit 0
    exit 0
fi

if [[ ${1:-} == --link ]]; then
    selected=$(zenity --entry --title='Send webpage to BOOX' --text='Paste a webpage URL (https:// or http://):') || exit 0
    [[ $selected == http://* || $selected == https://* ]] || fail 'Enter a webpage URL starting with https:// or http://.'
    set -- "$selected"
elif [[ ${1:-} == --pdf ]]; then
    selected=$(zenity --file-selection --title='Send a PDF to BOOX' --file-filter='PDF files | *.pdf *.PDF') || exit 0
    set -- "$selected"
fi

# %U launchers can supply PDFs as file:// URIs. Decode without evaluating text.
items=()
for path in "$@"; do
    if [[ $path == file://* ]]; then
        path=${path#file://}
        [[ $path != localhost/* ]] || path=${path#localhost}
        [[ $path == /* ]] || fail 'Only local PDF files are supported.'
        decoded=''
        while [[ -n $path ]]; do
            if [[ $path == %* ]]; then
                hex=${path:1:2}
                [[ $hex =~ ^[[:xdigit:]]{2}$ && $hex != 00 ]] || fail 'Invalid file URI.'
                printf -v byte '%b' "\\x$hex"
                decoded+=$byte
                path=${path:3}
            else
                decoded+=${path:0:1}
                path=${path:1}
            fi
        done
        path=$decoded
    fi
    items+=("$path")
done

# Validate the entire selection before sending anything.
for path in "${items[@]}"; do
    if [[ $path == http://* || $path == https://* ]]; then
        [[ $path =~ ^https?://[^/?#[:space:]]+ && ! $path =~ [[:space:][:cntrl:]] ]] || fail "Invalid webpage URL:\n$path"
        continue
    fi
    [[ -f $path && -r $path && ${path,,} == *.pdf ]] || fail "Select a readable PDF file:\n$path"
    [[ $(file --brief --mime-type -- "$path") == application/pdf ]] || fail "This is not a PDF:\n$path"
done

# Keep the pending selection while the user repairs the connection.
while :; do
    if state=$(timeout 5 adb -d get-state 2>&1) && [[ $state == device ]]; then
        serial=$(adb -d get-serialno 2>&1) || fail "Cannot identify BOOX: $serial"
        break
    fi
    problem='No saved wireless connection. Set up a connection, or connect USB and authorize this computer.'
    if [[ -f $config ]]; then
        wireless_tools
        mapfile -t settings < "$config"
        problem='Saved wireless settings are incomplete. Run connection setup again.'
        if (( ${#settings[@]} == 3 )); then
            network=${settings[0]} endpoint=${settings[1]} identity=${settings[2]}
            active=$(nmcli -g UUID connection show --active) || active=''
            problem='Your saved home network is not active. Connect to it, use USB, or set up your current trusted network.'
            if [[ $'\n'$active$'\n' == *$'\n'"$network"$'\n'* ]]; then
                problem='BOOX is not reachable. Wake it and check Wireless debugging. After reboot, USB setup may be needed, or the paired connection port may have changed.'
                if restore_connection; then
                    serial=$endpoint
                    break
                fi
                problem='Your remembered BOOX was not found. Wake it, connect it to this home network, and turn on Wireless debugging. Then retry; its new address and port will be discovered automatically. If discovery is unavailable, open setup and enter its current connection address. USB-based setup on port 5555 may need USB again after reboot.'

            fi
        fi
    fi
    action=$(choose "$problem\n\nYour selected files or webpage will wait here while you reconnect." retry 'I fixed it — retry' setup 'Open connection wizard') || exit 0
    case $action in
        setup) setup_wireless || exit 0 ;;
        retry) ;;
        *) exit 0 ;;
    esac
done

device=(adb -s "$serial")

# Encode UTF-8 bytes, including spaces, quotes, # and %, for Android's file URI.
file_uri() {
    local LC_ALL=C value=$1 char hex i
    REPLY='file://'
    for ((i=0; i<${#value}; i++)); do
        char=${value:i:1}
        case $char in
            [a-zA-Z0-9/._~-]) REPLY+=$char ;;
            *) printf -v hex '%%%02X' "'$char"; REPLY+=$hex ;;
        esac
    done
}

for path in "${items[@]}"; do
    if [[ $path == http://* || $path == https://* ]]; then
        # Single-quote for Android's shell, escaping embedded apostrophes.
        quoted=${path//\'/\'\\\'\'}
        if ! output=$("${device[@]}" shell "am start -W -a android.intent.action.VIEW -d '$quoted'" 2>&1) ||
            [[ $output == *Error* || $output == *Exception* || $output == *'unable to resolve'* ]]; then
            fail "BOOX could not open the webpage:\n$path\n\n$output"
        fi
        continue
    fi
    output=$("${device[@]}" shell 'mkdir -p /sdcard/Books' 2>&1) || fail "Cannot create /sdcard/Books:\n$output"
    # Absolute local paths also prevent leading '-' from becoming an adb option.
    [[ $path == /* ]] || path=$PWD/$path
    destination=/sdcard/Books/${path##*/}
    output=$("${device[@]}" push "$path" "$destination" 2>&1) || fail "Transfer failed:\n$path\n\n$output"
    file_uri "$destination"
    # adb shell joins arguments into a remote shell command; quote there too.
    if ! output=$("${device[@]}" shell "am start -W -a android.intent.action.VIEW -d '$REPLY' -t application/pdf" 2>&1) ||
        [[ $output == *Error* || $output == *Exception* || $output == *'unable to resolve'* ]]; then
        fail "The PDF was copied, but BOOX could not open it:\n$path\n\n$output"
    fi
done
message info "Sent and opened ${#items[@]} item(s) on BOOX."
