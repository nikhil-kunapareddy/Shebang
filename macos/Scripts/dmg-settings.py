# dmgbuild settings for the drag-to-install DMG; build-app.sh --dmg passes the paths:
#
#   dmgbuild -s Scripts/dmg-settings.py -D app=<Shebang.app> -D background=<tiff> -D icon=<icns> Shebang <out.dmg>
#
# Geometry matches Scripts/make-dmg-background.swift (600x400 pt window, icons centred at y 190).
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
app_name = os.path.basename(app)

format = "ULFO"  # LZFSE, readable on macOS 10.11 and later
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

window_rect = ((200, 150), (600, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {app_name: (150, 190), "Applications": (450, 190)}
# No hide_extensions: it sets com.apple.FinderInfo on the bundle, which breaks strict signature checks.
# Finder hides the .app extension by default anyway.
