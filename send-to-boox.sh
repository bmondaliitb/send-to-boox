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

if (( $# == 0 )); then
    selected=$(zenity --file-selection --title='Send a PDF to BOOX' --file-filter='PDF files | *.pdf *.PDF') || exit 0
    set -- "$selected"
fi

# Validate the entire selection before transferring anything.
for path in "$@"; do
    [[ -f $path && -r $path && ${path,,} == *.pdf ]] || fail "Select a readable PDF file:\n$path"
    [[ $(file --brief --mime-type -- "$path") == application/pdf ]] || fail "This is not a PDF:\n$path"
done

# -d selects USB only and refuses to guess if multiple USB devices are attached.
if ! state=$(adb -d get-state 2>&1) || [[ $state != device ]]; then
    fail "Cannot reach BOOX over USB. Connect it, enable USB debugging, and accept the authorization prompt on BOOX. Disconnect other Android USB devices.\n\n$state"
fi
serial=$(adb -d get-serialno 2>&1) || fail "Cannot identify BOOX:\n$serial"
device=(adb -s "$serial")
output=$("${device[@]}" shell 'mkdir -p /sdcard/Books' 2>&1) || fail "Cannot create /sdcard/Books:\n$output"

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

for path in "$@"; do
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
message info "Sent and opened $# PDF file(s) on BOOX."
