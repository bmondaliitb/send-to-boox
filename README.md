# Send to BOOX

Run once from this folder in your Ubuntu desktop session (not with `sudo`):

```bash
sudo apt install adb zenity file libglib2.0-bin xdg-user-dirs desktop-file-utils
bash install.sh
```

Connect BOOX by USB, enable USB debugging, and accept its authorization prompt.
Right-click the desktop **Send to BOOX** icon → **Allow Launching** if needed.

**Download PDF → drag it from Files onto Send to BOOX → PDF opens on BOOX.**
If your browser's download item cannot be dragged, use **Show in folder** first.
Alternatively, right-click a PDF → **Open With → Send to BOOX** (under **All
Applications**), or double-click the icon → **Send a PDF**. Your default PDF app
is unchanged. Success and errors appear in graphical dialogs.

**Webpages:** right-click the launcher → **Send webpage**, then paste an
`https://` or `http://` URL. This action may also appear in the applications
menu. You can drag a browser link onto the icon if your desktop supports URL
drops. BOOX opens the link in its browser and needs an internet connection;
the webpage is not copied for offline reading. Rerun `bash install.sh` to
update an existing installation.

The launcher now uses `%U` so drops can pass both URLs and local PDF file URIs.

**Easy wireless setup / reconnect:** rerun `bash install.sh`, then:

1. Connect laptop and BOOX to your home network. For first-time setup, connect
   BOOX by USB and accept its debugging authorization prompt.
2. Double-click **Send to BOOX → Set up / connect wireless**.
3. Confirm the suggested BOOX IP and click **Connect**. Setup tries to detect
   the IP over USB, otherwise remembers your last address; if blank, enter
   the address shown in BOOX's Wi-Fi settings.
4. When the success dialog appears, unplug USB and send normally.

Setup remembers the home connection (asks you to choose if ambiguous), enables
TCP debugging over USB, and establishes and checks the wireless connection.
The same menu reconnects later without USB if TCP debugging is still enabled.
You can also access setup through the launcher's right-click action.
USB is preferred; wireless is only used while the saved NetworkManager
connection is active, and the BOOX serial is checked before sending.

Wireless setup needs `nmcli` (standard on Ubuntu Desktop). BOOX may disable
TCP debugging after reboot: reconnect USB and repeat setup. If its IP changes,
repeat setup; a DHCP reservation in your router avoids this. Use TCP debugging
only on a trusted home network. Settings are stored in
`~/.config/send-to-boox/wireless` (or `$XDG_CONFIG_HOME/send-to-boox/wireless`).

Desktop drops depend on the GNOME icon extension, not just Ubuntu's version.
The DING code installed on the development machine (Ubuntu 26.04) includes
launcher drop handling; an interactive drop was not verified. Upstream's
[DING changelog](https://www.rastersoft.com/programas/ding.html) also records
trusted-launcher drop support in 51.0.7. Use Open With if your extension does
not forward drops; installing the launcher cannot add that capability.

For files, only readable `.pdf` files identified as PDF by `file` are accepted. Connect
only the intended Android USB device. Files go to `/sdcard/Books/`; existing
files with the same name are overwritten. Multiple PDFs open in sequence,
leaving the last visible. A failure stops the batch; earlier copies remain.
