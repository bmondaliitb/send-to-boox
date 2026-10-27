#!/usr/bin/env bash
set -euo pipefail

message() {
    local kind=$1 text=$2
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

connect_wireless() {
    local output state attempt
    # adbd can take a moment to restart after tcpip.
    for attempt in 1 2 3; do
        output=$(timeout 5 adb connect "$endpoint" 2>&1) || true
        if state=$(timeout 5 adb -s "$endpoint" get-state 2>&1) && [[ $state == device ]]; then
            return
        fi
        [[ $attempt == 3 ]] || sleep 1
    done
    fail "Cannot reach BOOX at $endpoint. Check its Wi-Fi/IP address and accept any debugging authorization prompt. After reboot, connect USB and run Set up wireless again.\n\n$output\n$state"
}

if [[ ${1:-} == --setup-wireless ]]; then
    wireless_tools
    saved=()
    [[ ! -f $config ]] || mapfile -t saved < "$config"
    networks=()
    while IFS=: read -r uuid type name; do
        case $type in
            802-11-wireless|802-3-ethernet) networks+=("$uuid" "$name") ;;
        esac
    done < <(nmcli --escape no -t -f UUID,TYPE,NAME connection show --active)
    (( ${#networks[@]} )) || fail 'Connect your laptop to your home Wi-Fi or Ethernet first.'
    network=''
    for ((i=0; i<${#networks[@]}; i+=2)); do
        if [[ ${networks[i]} == "${saved[0]:-}" || ${#networks[@]} == 2 ]]; then
            network=${networks[i]}
            break
        fi
    done
    if [[ -z $network ]]; then
        network=$(zenity --list --title='Set up BOOX wireless' --text='Select your home network connection:' \
            --column=UUID --column=Network --hide-column=1 --print-column=1 "${networks[@]}") || exit 0
    fi
    [[ -n $network ]] || exit 0
    network_name=$network
    for ((i=0; i<${#networks[@]}; i+=2)); do
        [[ ${networks[i]} != "$network" ]] || network_name=${networks[i+1]}
    done
    suggested=${saved[1]:-}
    suggested=${suggested%:5555}
    usb=false
    if [[ $(adb -d get-state 2>/dev/null) == device ]]; then
        usb=true
        address=$(timeout 5 adb -d shell ip -o -4 addr show wlan0 2>/dev/null) || address=''
        if [[ $address =~ inet[[:space:]]+([0-9.]+)/ ]]; then
            suggested=${BASH_REMATCH[1]}
        fi
    fi
    ip=$(zenity --entry --title='Set up / connect BOOX wireless' --ok-label=Connect \
        --entry-text="$suggested" --text="Home connection: $network_name\n\nKeep BOOX on the same home network. For first-time setup, connect USB and accept its debugging prompt before continuing.\n\nConfirm BOOX's Wi-Fi IP below (find it in BOOX Wi-Fi settings if blank):") || exit 0
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail 'Enter an IPv4 address, without a port.'
    IFS=. read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || fail 'Invalid IPv4 address.'
    done
    printf -v endpoint '%d.%d.%d.%d:5555' \
        "$((10#${octets[0]}))" "$((10#${octets[1]}))" \
        "$((10#${octets[2]}))" "$((10#${octets[3]}))"
    # Check again in case USB was connected while the dialog was open.
    if [[ $usb == true || $(adb -d get-state 2>/dev/null) == device ]]; then
        output=$(adb -d tcpip 5555 2>&1) || fail "Could not enable wireless debugging:\n$output"
    fi
    connect_wireless
    identity=$(timeout 10 adb -s "$endpoint" shell getprop ro.serialno) || fail 'Cannot identify BOOX.'
    identity=${identity//$'\r'/}
    [[ -n $identity && $identity != *$'\n'* ]] || fail 'BOOX did not report a device serial number.'
    mkdir -p -- "${config%/*}" || fail 'Cannot create wireless settings directory.'
    temporary=$(mktemp "${config}.XXXXXX") || fail 'Cannot save wireless settings.'
    printf '%s\n' "$network" "$endpoint" "$identity" > "$temporary"
    mv -- "$temporary" "$config" || fail 'Cannot save wireless settings.'
    message info 'Wireless mode is ready. You can unplug USB. PDFs and webpages will use wireless while this home network connection is active.'
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

# Prefer USB; wireless is restricted to the saved NetworkManager profile.
if state=$(adb -d get-state 2>&1) && [[ $state == device ]]; then
    serial=$(adb -d get-serialno 2>&1) || fail "Cannot identify BOOX:\n$serial"
else
    [[ -f $config ]] || fail "Cannot reach BOOX over USB. Connect and authorize it, or choose Set up wireless from the launcher.\n\n$state"
    wireless_tools
    mapfile -t settings < "$config"
    (( ${#settings[@]} == 3 )) || fail 'Wireless settings are invalid. Run Set up wireless again.'
    network=${settings[0]} endpoint=${settings[1]} identity=${settings[2]}
    active=$(nmcli -g UUID connection show --active) || fail 'Cannot check your home network connection.'
    [[ $'\n'$active$'\n' == *$'\n'"$network"$'\n'* ]] ||
        fail 'USB is disconnected and your saved home network is not active. Connect to your home network or use USB.'
    connect_wireless
    actual=$(timeout 10 adb -s "$endpoint" shell getprop ro.serialno) || fail 'Cannot identify wireless BOOX.'
    [[ ${actual//$'\r'/} == "$identity" ]] || fail 'The device at the saved IP address is not your configured BOOX. Run Set up wireless again.'
    serial=$endpoint
fi
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
