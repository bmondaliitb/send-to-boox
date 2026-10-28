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

**Guided connection setup:** rerun `bash install.sh`, then open
**Send to BOOX → Set up / connect wireless**. All connection steps run in
graphical dialogs; no terminal commands are needed during setup.

1. Select your trusted home network and connect BOOX to the same network.
2. Choose an existing wireless connection, wireless pairing, or USB setup.
3. Follow the instructions on screen. USB setup checks authorization and detects
   the Wi-Fi address when possible. Wireless pairing asks for the pairing address
   and six-digit code, then the separate connection address on the main Wireless
   debugging screen.
4. If a step fails, correct the address and retry, or return to choose another
   method. The help option explains hidden developer settings and can open
   Android About device or Developer options over authorized USB.
5. Once the connection is verified, unplug USB and send normally.

The wizard shows progress during connection and pairing. Cancel preserves the
previous saved connection. If sending fails to connect, the same wizard is
available immediately; the selected PDF or webpage waits until setup finishes.
USB is preferred. Wireless sends are restricted to the saved NetworkManager
profile and verify the BOOX serial number before sending.

USB-based wireless access may be disabled by a BOOX reboot. Repeat USB setup
when that happens. Android wireless pairing, if exposed by BOOX firmware, avoids
USB for subsequent setup, but you may need to enable Wireless debugging after
reboot. The app remembers the device serial and trusted network, discovers new
connection addresses through ADB mDNS, and verifies the device before saving
its new address. This also works after a computer restart. If the network blocks
discovery, the wizard still accepts the current connection address manually.
The pairing port is not the connection port. Remembering settings cannot turn
Wireless debugging back on when BOOX firmware disables it.

Wireless setup needs `nmcli` (standard on Ubuntu Desktop), `timeout`, and an ADB
version supporting `adb pair` for pairing. Use only a trusted home network.
Connection settings are saved in `~/.config/send-to-boox/wireless` (or
`$XDG_CONFIG_HOME/send-to-boox/wireless`). Pairing codes are not saved by the app.

Run the mocked connection-flow checks with:

```bash
python3 -m unittest discover -s tests -v
```

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
