"""
Fusion 360 script: STL merge/boolean/extrude pipeline.

Run via Fusion's Scripts and Add-Ins panel (Shift+S -> Scripts -> Run).
Edit the CONFIG block below per job -- no Fusion menus required beyond
Run.

Pipeline:
  1. Import one or more STL files as mesh bodies into the active design.
  2. Convert each mesh to BRep (solid), at a chosen refinement.
  3. Boolean-combine them (or combine against an existing body already
     in the design, referenced by name).
  4. Optionally add a sketch + extrude on a named face/plane of the
     result (params below; leave SKETCH = None to skip).
  5. Export the result to STEP and/or STL.

Tested against the Fusion API as of 2026; class/method names are the
current stable ones (ConvertMeshFeatures, CombineFeatureInput,
ExtrudeFeatureInput). If Autodesk renames something, the error will
name the missing attribute.
"""

import traceback
import adsk.core
import adsk.fusion

# ---------------------------------------------------------------------
# CONFIG -- the only section you should need to touch between runs.
# ---------------------------------------------------------------------

STL_INPUTS = [
    "/home/solace/cad/parts/bracket_base.stl",
    "/home/solace/cad/parts/boss_insert.stl",
]

# Mesh-to-BRep refinement: 'Low', 'Medium', 'High'
MESH_REFINEMENT = "Medium"

# Boolean operation combining STL_INPUTS[1:] into STL_INPUTS[0]:
# 'Join', 'Cut', 'Intersect'
BOOLEAN_OP = "Join"

# Optional sketch+extrude on top of the combined result.
# Set to None to skip this step entirely.
#
# "plane" accepts either:
#   - a fixed datum: 'XY' | 'XZ' | 'YZ'
#   - a face-selection rule, as a dict:
#       {"select_face": "largest_planar"}
#       {"select_face": "top"}       # planar face with highest centroid Z
#       {"select_face": "bottom"}    # planar face with lowest centroid Z
#       {"select_face": "normal", "vector": (0, 0, 1)}  # closest-matching normal
#
# NOTE on circle_center when using select_face: Fusion derives the
# sketch's local 2D origin/axes from the face's own parameterization,
# which is not something this script controls. (0, 0) lands wherever
# Fusion puts that face's origin -- run once, check the result, and
# adjust circle_center to compensate. This is a real limit of
# face-based sketching, not a bug to chase.
SKETCH = {
    "plane": {"select_face": "top"},
    "circle_center": (0, 0),
    "circle_radius_cm": 0.5,
    "extrude_distance_cm": 1.0,
    "operation": "Join",     # 'Join' | 'Cut' | 'Intersect' | 'NewBody'
}

EXPORT_STEP_PATH = "/home/solace/cad/out/merged.step"
EXPORT_STL_PATH = "/home/solace/cad/out/merged.stl"

# ---------------------------------------------------------------------


def convert_mesh_to_brep(design, mesh_body, refinement_str):
    refinement_map = {
        "Low": adsk.fusion.MeshRefinementSettings.MeshRefinementLow,
        "Medium": adsk.fusion.MeshRefinementSettings.MeshRefinementMedium,
        "High": adsk.fusion.MeshRefinementSettings.MeshRefinementHigh,
    }
    root = design.rootComponent
    convert_feats = root.features.convertMeshFeatures
    convert_input = convert_feats.createInput(mesh_body)
    convert_input.refinementSettings = refinement_map[refinement_str]
    feature = convert_feats.add(convert_input)
    # The resulting BRep body is the first (only) body the feature produced.
    return feature.bodies.item(0)


def import_stl_as_mesh(app, design, path):
    import_mgr = app.importManager
    import_options = import_mgr.createSTLImportOptions(path)
    import_options.isBodiesCombined = True
    # Import into the active design (root component), not a new document.
    import_mgr.importToTarget2(import_options, design.rootComponent)
    # The most recently added mesh body is the one just imported.
    mesh_bodies = design.rootComponent.meshBodies
    return mesh_bodies.item(mesh_bodies.count - 1)


def boolean_combine(root, target_body, tool_bodies, op_str):
    op_map = {
        "Join": adsk.fusion.FeatureOperations.JoinFeatureOperation,
        "Cut": adsk.fusion.FeatureOperations.CutFeatureOperation,
        "Intersect": adsk.fusion.FeatureOperations.IntersectFeatureOperation,
    }
    combine_feats = root.features.combineFeatures
    tool_collection = adsk.core.ObjectCollection.create()
    for b in tool_bodies:
        tool_collection.add(b)
    combine_input = combine_feats.createInput(target_body, tool_collection)
    combine_input.operation = op_map[op_str]
    combine_input.isKeepToolBodies = False
    feature = combine_feats.add(combine_input)
    return feature.bodies.item(0) if feature.bodies.count else target_body


def _planar_faces(body):
    faces = []
    for face in body.faces:
        if face.geometry.surfaceType == adsk.core.SurfaceTypes.PlaneSurfaceType:
            faces.append(face)
    return faces


def _face_centroid_z(face):
    # BRepFace has no direct centroid property; approximate with the
    # bounding box center, which is exact for a planar face's Z extent.
    bbox = face.boundingBox
    return (bbox.minPoint.z + bbox.maxPoint.z) / 2.0


def select_face(body, rule):
    planar = _planar_faces(body)
    if not planar:
        raise RuntimeError("No planar faces found on the merged body -- "
                            "cannot apply a face-selection rule. Fall back "
                            "to a fixed datum plane ('XY'/'XZ'/'YZ') instead.")

    kind = rule["select_face"]
    if kind == "largest_planar":
        return max(planar, key=lambda f: f.area)
    elif kind == "top":
        return max(planar, key=_face_centroid_z)
    elif kind == "bottom":
        return min(planar, key=_face_centroid_z)
    elif kind == "normal":
        target = adsk.core.Vector3D.create(*rule["vector"])
        target.normalize()

        def alignment(face):
            n = face.geometry.normal
            n.normalize()
            return n.dotProduct(target)

        return max(planar, key=alignment)
    else:
        raise ValueError("Unknown select_face rule: {}".format(kind))


def sketch_and_extrude(root, body, cfg):
    op_map = {
        "Join": adsk.fusion.FeatureOperations.JoinFeatureOperation,
        "Cut": adsk.fusion.FeatureOperations.CutFeatureOperation,
        "Intersect": adsk.fusion.FeatureOperations.IntersectFeatureOperation,
        "NewBody": adsk.fusion.FeatureOperations.NewBodyFeatureOperation,
    }
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

    sketch = root.sketches.add(plane)
    cx, cy = cfg["circle_center"]
    center_point = adsk.core.Point3D.create(cx, cy, 0)
    sketch.sketchCurves.sketchCircles.addByCenterRadius(
        center_point, cfg["circle_radius_cm"]
    )
    profile = sketch.profiles.item(0)

    extrudes = root.features.extrudeFeatures
    ext_input = extrudes.createInput(profile, op_map[cfg["operation"]])
    distance = adsk.core.ValueInput.createByReal(cfg["extrude_distance_cm"])
    ext_input.setDistanceExtent(False, distance)
    extrudes.add(ext_input)


def export_result(app, design, step_path, stl_path):
    export_mgr = design.exportManager
    root = design.rootComponent

    if step_path:
        step_options = export_mgr.createSTEPExportOptions(step_path, root)
        export_mgr.execute(step_options)

    if stl_path:
        stl_options = export_mgr.createSTLExportOptions(root, stl_path)
        stl_options.meshRefinement = adsk.fusion.MeshRefinementSettings.MeshRefinementHigh
        export_mgr.execute(stl_options)


def run(context):
    ui = None
    try:
        app = adsk.core.Application.get()
        ui = app.userInterface
        design = adsk.fusion.Design.cast(app.activeProduct)
        root = design.rootComponent

        if len(STL_INPUTS) < 1:
            ui.messageBox("STL_INPUTS is empty -- nothing to do.")
            return

        brep_bodies = []
        for path in STL_INPUTS:
            mesh_body = import_stl_as_mesh(app, design, path)
            brep = convert_mesh_to_brep(design, mesh_body, MESH_REFINEMENT)
            brep_bodies.append(brep)

        if len(brep_bodies) > 1:
            result_body = boolean_combine(
                root, brep_bodies[0], brep_bodies[1:], BOOLEAN_OP
            )
        else:
            result_body = brep_bodies[0]

        if SKETCH is not None:
            sketch_and_extrude(root, result_body, SKETCH)

        export_result(app, design, EXPORT_STEP_PATH, EXPORT_STL_PATH)

        ui.messageBox(
            "Done.\nSTEP: {}\nSTL: {}".format(EXPORT_STEP_PATH, EXPORT_STL_PATH)
        )

    except Exception:
        if ui:
            ui.messageBox("Failed:\n{}".format(traceback.format_exc()))
