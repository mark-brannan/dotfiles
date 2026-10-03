"""
Fusion 360 script: STL merge/boolean/extrude pipeline.

Run via Fusion's Scripts and Add-Ins panel (Shift+S -> Scripts -> Run).
Edit the CONFIG block below per job -- no Fusion menus required beyond
Run.

Pipeline:
  1. Import one or more STL files as mesh bodies into the active design.
  2. Convert each mesh to BRep (solid).
  3. Boolean-combine them into the first one.
  4. Optionally add a sketch circle + extrude on a datum plane or a
     selected face of the result (leave SKETCH = None to skip).
  5. Export the result to STEP and/or STL.

Status: never run against a live Fusion session. Every API call below
was checked against Autodesk's published API reference
(github.com/AutodeskFusion360/FusionAPIReference), but treat the first
run as validation. MeshConvertFeatures is a preview API (July 2025)
and may change; if Autodesk renames something, the error names the
missing attribute.
"""

import os
import traceback

import adsk.core
import adsk.fusion

# ---------------------------------------------------------------------
# CONFIG -- the only section you should need to touch between runs.
# Paths are as Fusion sees them: Fusion runs on Windows or macOS, so a
# WSL path needs its \\wsl.localhost\<distro>\... form.
# ---------------------------------------------------------------------

# The first entry is the target body; the rest are tool bodies.
STL_INPUTS = [
    # r"C:\path\to\cad\part_a.stl",
    # r"C:\path\to\cad\part_b.stl",
]

# STL files carry no units; say what these were authored in:
# 'mm' | 'cm' | 'm' | 'in' | 'ft'
STL_UNITS = "mm"

# Mesh-to-BRep method:
#   'Faceted'   -- one BRep face per triangle (always works, heavy)
#   'Prismatic' -- merges coplanar triangles into single faces (best for
#                  mechanical parts; needs the mesh to have face groups)
MESH_CONVERT_METHOD = "Faceted"

# Boolean operation combining STL_INPUTS[1:] into STL_INPUTS[0]:
# 'Join', 'Cut', 'Intersect'
BOOLEAN_OP = "Join"

# Optional sketch circle + extrude on the combined result.
# Set to None to skip this step entirely.
#
# "plane" accepts either:
#   - a fixed datum: 'XY' | 'XZ' | 'YZ'
#   - a face-selection rule, as a dict. These assume
#     MESH_CONVERT_METHOD = "Prismatic": under "Faceted" every triangle
#     is its own face, so a rule picks one triangle, whose plane is
#     arbitrary on a curved or chamfered area.
#       {"select_face": "largest_planar"}
#       {"select_face": "top"}       # planar face with highest centroid Z
#       {"select_face": "bottom"}    # planar face with lowest centroid Z
#       {"select_face": "normal", "vector": (0, 0, 1)}  # closest outward normal
#
# "circle_center" is a model-space point (x, y, z) in cm; the script
# projects it onto the sketch plane, so it means the same thing whichever
# plane or face is chosen.
SKETCH = {
    "plane": "XY",
    "circle_center": (0, 0, 0),
    "circle_radius_cm": 0.5,
    "extrude_distance_cm": 1.0,
    "operation": "Join",     # 'Join' | 'Cut' | 'Intersect' | 'NewBody'
}

# Set either to None to skip that format.
EXPORT_STEP_PATH = r"C:\path\to\cad\out\merged.step"
EXPORT_STL_PATH = r"C:\path\to\cad\out\merged.stl"

# ---------------------------------------------------------------------

OPERATIONS = {
    "Join": adsk.fusion.FeatureOperations.JoinFeatureOperation,
    "Cut": adsk.fusion.FeatureOperations.CutFeatureOperation,
    "Intersect": adsk.fusion.FeatureOperations.IntersectFeatureOperation,
    "NewBody": adsk.fusion.FeatureOperations.NewBodyFeatureOperation,
}


def check_config():
    """Every problem with the CONFIG block, before the design is touched."""
    problems = []
    if not STL_INPUTS:
        problems.append("STL_INPUTS is empty.")
    for path in STL_INPUTS:
        if not os.path.isfile(path):
            problems.append("STL not found: {}".format(path))
    for path in (EXPORT_STEP_PATH, EXPORT_STL_PATH):
        if path and not os.path.isdir(os.path.dirname(path) or "."):
            problems.append("Export folder missing: {}".format(path))
    return problems


def import_stl_as_mesh(design, path, units_str):
    units_map = {
        "mm": adsk.fusion.MeshUnits.MillimeterMeshUnit,
        "cm": adsk.fusion.MeshUnits.CentimeterMeshUnit,
        "m": adsk.fusion.MeshUnits.MeterMeshUnit,
        "in": adsk.fusion.MeshUnits.InchMeshUnit,
        "ft": adsk.fusion.MeshUnits.FootMeshUnit,
    }
    root = design.rootComponent
    if design.designType == adsk.fusion.DesignTypes.ParametricDesignType:
        # A parametric design only accepts a mesh inside a base feature
        # that is open for editing (MeshBodies.add docs).
        base = root.features.baseFeatures.add()
        base.startEdit()
        try:
            meshes = root.meshBodies.add(path, units_map[units_str], base)
        finally:
            base.finishEdit()
    else:
        meshes = root.meshBodies.add(path, units_map[units_str])
    if meshes is None or meshes.count == 0:
        raise RuntimeError("Fusion imported no mesh from {}".format(path))
    return meshes.item(0)


def convert_mesh_to_brep(design, mesh_body, method_str):
    method_map = {
        "Faceted": adsk.fusion.MeshConvertMethodTypes.FacetedMeshConvertMethodType,
        "Prismatic": adsk.fusion.MeshConvertMethodTypes.PrismaticMeshConvertMethodType,
    }
    convert_feats = design.rootComponent.features.meshConvertFeatures
    convert_input = convert_feats.createInput([mesh_body])
    convert_input.meshConvertMethodType = method_map[method_str]
    feature = convert_feats.add(convert_input)
    if feature is None or feature.bodies.count == 0:
        raise RuntimeError("Mesh convert produced no body for {}".format(
            mesh_body.name))
    return feature.bodies.item(0)


def boolean_combine(root, target_body, tool_bodies, op_str):
    combine_feats = root.features.combineFeatures
    tool_collection = adsk.core.ObjectCollection.create()
    for b in tool_bodies:
        tool_collection.add(b)
    combine_input = combine_feats.createInput(target_body, tool_collection)
    combine_input.operation = OPERATIONS[op_str]
    combine_input.isKeepToolBodies = False
    feature = combine_feats.add(combine_input)
    return feature.bodies.item(0) if feature.bodies.count else target_body


def _planar_faces(body):
    return [face for face in body.faces
            if face.geometry.surfaceType == adsk.core.SurfaceTypes.PlaneSurfaceType]


def _outward_normal(face):
    # The evaluator honours the face's orientation; face.geometry.normal
    # can point into the body when the face is reversed.
    _, normal = face.evaluator.getNormalAtPoint(face.pointOnFace)
    normal.normalize()
    return normal


def select_face(body, rule):
    planar = _planar_faces(body)
    if not planar:
        raise RuntimeError("No planar faces found on the merged body -- "
                           "cannot apply a face-selection rule. Fall back "
                           "to a fixed datum plane ('XY'/'XZ'/'YZ') instead.")

    kind = rule["select_face"]
    if kind == "largest_planar":
        return max(planar, key=lambda f: f.area)
    if kind == "top":
        return max(planar, key=lambda f: f.centroid.z)
    if kind == "bottom":
        return min(planar, key=lambda f: f.centroid.z)
    if kind == "normal":
        target = adsk.core.Vector3D.create(*rule["vector"])
        target.normalize()
        return max(planar, key=lambda f: _outward_normal(f).dotProduct(target))
    raise ValueError("Unknown select_face rule: {}".format(kind))


def sketch_and_extrude(root, body, cfg):
    """Returns the body to export: the extruded-into body, or None for
    NewBody, where the export takes the whole root component."""
    plane_spec = cfg["plane"]
    if isinstance(plane_spec, dict):
        plane = select_face(body, plane_spec)
    else:
        plane_map = {
            "XY": root.xYConstructionPlane,
            "XZ": root.xZConstructionPlane,
            "YZ": root.yZConstructionPlane,
        }
        plane = plane_map[plane_spec]

    # addWithoutEdges, not add: add() projects a face's edges into the
    # sketch, and the face region would then compete with the circle for
    # profiles.item(0).
    sketch = root.sketches.addWithoutEdges(plane)
    center = sketch.modelToSketchSpace(
        adsk.core.Point3D.create(*cfg["circle_center"]))
    center.z = 0
    sketch.sketchCurves.sketchCircles.addByCenterRadius(
        center, cfg["circle_radius_cm"])
    profile = sketch.profiles.item(0)

    extrudes = root.features.extrudeFeatures
    ext_input = extrudes.createInput(profile, OPERATIONS[cfg["operation"]])
    if cfg["operation"] in ("Cut", "Intersect"):
        # Only these honour participantBodies; keep other bodies in the
        # design out of the cut.
        ext_input.participantBodies = [body]
    distance = adsk.core.ValueInput.createByReal(cfg["extrude_distance_cm"])
    ext_input.setDistanceExtent(False, distance)
    feature = extrudes.add(ext_input)
    if cfg["operation"] == "NewBody":
        return None
    return feature.bodies.item(0) if feature.bodies.count else body


def export_result(design, body, step_path, stl_path):
    export_mgr = design.exportManager
    root = design.rootComponent

    if step_path:
        # STEP export takes a component only, so this is the whole root.
        step_options = export_mgr.createSTEPExportOptions(step_path, root)
        export_mgr.execute(step_options)

    if stl_path:
        stl_options = export_mgr.createSTLExportOptions(body or root, stl_path)
        stl_options.meshRefinement = adsk.fusion.MeshRefinementSettings.MeshRefinementHigh
        export_mgr.execute(stl_options)


def run(context):
    ui = None
    try:
        app = adsk.core.Application.get()
        ui = app.userInterface
        design = adsk.fusion.Design.cast(app.activeProduct)
        if not design:
            ui.messageBox("No active Fusion design -- open or create one first.")
            return

        problems = check_config()
        if problems:
            ui.messageBox("Fix the CONFIG block first:\n" + "\n".join(problems))
            return

        root = design.rootComponent
        brep_bodies = []
        for path in STL_INPUTS:
            mesh_body = import_stl_as_mesh(design, path, STL_UNITS)
            brep_bodies.append(
                convert_mesh_to_brep(design, mesh_body, MESH_CONVERT_METHOD))

        result_body = brep_bodies[0]
        if len(brep_bodies) > 1:
            result_body = boolean_combine(
                root, brep_bodies[0], brep_bodies[1:], BOOLEAN_OP)

        if SKETCH is not None:
            result_body = sketch_and_extrude(root, result_body, SKETCH)

        export_result(design, result_body, EXPORT_STEP_PATH, EXPORT_STL_PATH)

        ui.messageBox(
            "Done.\nSTEP: {}\nSTL: {}".format(EXPORT_STEP_PATH, EXPORT_STL_PATH))

    except Exception:
        if ui:
            ui.messageBox("Failed:\n{}".format(traceback.format_exc()))
