#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for command in adb zenity file gio xdg-user-dir update-desktop-database; do
    if ! command -v "$command" >/dev/null; then
        printf 'Missing %s. Install prerequisites, then rerun:\n' "$command" >&2
        printf 'sudo apt install adb zenity file libglib2.0-bin xdg-user-dirs desktop-file-utils\n' >&2
        exit 1
    fi
done

bin=$HOME/.local/bin
applications=${XDG_DATA_HOME:-$HOME/.local/share}/applications
desktop=$(xdg-user-dir DESKTOP)
[[ -n $desktop && $desktop != "$HOME" ]] || desktop=$HOME/Desktop
mkdir -p -- "$bin" "$applications" "$desktop"
install -m 755 -- "$source_dir/send-to-boox.sh" "$bin/send-to-boox"

# Quote Exec according to both desktop-entry string and command-line rules.
executable=$bin/send-to-boox
[[ $executable != *$'\n'* && $executable != *$'\r'* && $executable != *'='* ]] || { echo 'Unsupported home directory name.' >&2; exit 1; }
executable=${executable//\\/\\\\}
executable=${executable//\"/\\\"}
executable=${executable//\$/\\\$}
executable=${executable//\`/\\\`}
executable=${executable//\\/\\\\}
executable=${executable//%/%%}
launcher=$applications/send-to-boox.desktop
while IFS= read -r line; do
    if [[ $line == 'Exec=send-to-boox '* ]]; then
        printf 'Exec="%s" %s\n' "$executable" "${line#Exec=send-to-boox }"
    else
        printf '%s\n' "$line"
    fi
done < "$source_dir/send-to-boox.desktop" > "$launcher"
chmod 755 -- "$launcher"
install -m 755 -- "$launcher" "$desktop/send-to-boox.desktop"
update-desktop-database "$applications"
if ! gio set "$desktop/send-to-boox.desktop" metadata::trusted true 2>/dev/null; then
    printf 'Right-click the desktop icon and choose Allow Launching.\n'
fi
printf '%s\n' 'Installed Send to BOOX.' \
    'Desktop drop support depends on your icon extension; try dropping a PDF.' \
    'Fallback: right-click PDF → Open With → Send to BOOX (look under All Applications).' \
    'Double-click the icon to send a PDF, send a webpage, or set up / connect wireless.' \
    'For webpages: right-click the launcher → Send webpage, then paste the URL.' \
    'For home Wi-Fi: double-click the icon → Set up / connect wireless.'
