# Fusion 360 scripts

Personal Fusion 360 automation, run from Fusion's own Scripts and Add-Ins
panel (Shift+S, Scripts, `+`, pick the script's folder, Run). Fusion wants
a folder holding `<name>.py` and `<name>.manifest` with matching names;
it will not load a bare `.py`. Not shell CLI tools: `adsk` is Fusion's
in-process API, unavailable outside it. Fusion runs on Windows or macOS,
so from WSL point it at the `\\wsl.localhost\<distro>\home\...` path.

- `merge_stl/` imports STL(s), converts mesh to BRep, boolean-combines,
  optionally sketches a circle and extrudes it on a datum plane or a
  geometrically selected face (largest planar / top / bottom /
  normal-match), and exports STEP+STL. Edit the `CONFIG` block at the top
  per job; it refuses to touch the design until the paths in it exist.
  Never yet run against a live Fusion: the first run is the validation.
