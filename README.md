# Medieval RTS

A web-first, isometric medieval real-time strategy game built from scratch with Godot 4.3.

## Development
- **Primary target:** Web (HTML5)
- **Engine:** Godot 4.3
- **Later target:** Android APK
- **Current prototype:** procedural isometric map, camera controls, mouse/touch selection, group selection and movement.

## Run
Open `project.godot` with Godot 4.3+ and press Play.

## Controls
- Left click: select unit
- Left drag: box-select
- Right click: move selected units
- WASD / arrow keys: move camera
- Mouse wheel: zoom

## Web
Web export is configured in `export_presets.cfg`. GitHub Actions builds a web artifact when code is pushed to `main`. Configure GitHub Pages to use **GitHub Actions** if you want deployment.

This is the foundation; gameplay systems will be added incrementally.
