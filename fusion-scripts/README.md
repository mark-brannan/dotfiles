# Fusion 360 scripts

Personal Fusion 360 automation, run from Fusion's own Scripts and Add-Ins
panel (Shift+S → Scripts → `+` → point at a file → Run). Not shell CLI
tools — `adsk` is Fusion's in-process API, unavailable outside it.

- `merge_stl.py` — import STL(s), convert mesh to BRep, boolean-combine,
  optional sketch+extrude on a fixed datum plane or a geometrically
  selected face (largest planar / top / bottom / normal-match), export
  STEP+STL. Edit the `CONFIG` block at the top per job. Untested against
  the live Fusion API — first run should be treated as a dry run.
