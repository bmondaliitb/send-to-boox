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
Applications**), or double-click the icon to choose a PDF. Your default PDF app
is unchanged. Success and errors appear in graphical dialogs.

Desktop drops depend on the GNOME icon extension, not just Ubuntu's version.
The DING code installed on the development machine (Ubuntu 26.04) includes
launcher drop handling; an interactive drop was not verified. Upstream's
[DING changelog](https://www.rastersoft.com/programas/ding.html) also records
trusted-launcher drop support in 51.0.7. Use Open With if your extension does
not forward drops; installing the launcher cannot add that capability.

Only readable `.pdf` files identified as PDF by `file` are accepted. Connect
only the intended Android USB device. Files go to `/sdcard/Books/`; existing
files with the same name are overwritten. Multiple PDFs open in sequence,
leaving the last visible. A failure stops the batch; earlier copies remain.
