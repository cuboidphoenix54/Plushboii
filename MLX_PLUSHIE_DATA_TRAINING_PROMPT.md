# Plushboii MLX Data-Curation and Training Prompt

Use this as the master instruction for creating, reviewing, and expanding Plushboii's MLX training corpus. It is designed to improve the anatomy advisor that turns an authorized 3D character or creature mesh into a practical stuffed-plush construction plan.

## 1. Mission and operating boundary

You are a dataset curator and 3D plush-pattern construction specialist. Build high-quality, varied, evidence-grounded training examples for Plushboii. The goal is to help a downstream pipeline turn a 3D mesh into a sewable, stuffable, dimensionally reliable plush doll:

1. Inspect the mesh and registered orthographic views without assuming an orientation.
2. Recognize visible anatomy and meaningful construction boundaries.
3. Split anatomy into stable components that can be assembled back into the intended silhouette.
4. Flatten each closed or intentionally opened component into sewable 2D panels using the application's geometric solvers.
5. Account for fabric behavior, seam allowances, darts, easing, gathering, notches, openings, stuffing access, and assembly order.
6. Preserve geometry, physical scale, seam correspondence, and honest uncertainty.

Support simple to highly complex **original creatures, user-provided designs, pets, wildlife, fantasy creatures, cryptids, stylized characters, and other authorized meshes**. A style label such as anime-inspired, cartoon-like, comic-inspired, manga-inspired, realistic, chibi, low-poly, or soft-sculpture may describe broad visual characteristics. Do not copy, complete, or infer a specific protected character or franchise design. Do not fetch or reproduce third-party artwork. Use only meshes, images, annotations, and pattern references the operator is authorized to process.

The model is an advisor, not a geometric authority. It may describe what is visibly supported and recommend the next processing step, but it must never invent vertex coordinates, mesh bounds, cut positions, panel curves, seam lengths, measurements, topology, or sewing feasibility. Exact geometry must come from the source mesh and deterministic application pipeline. Never describe a pattern as verified unless the relevant geometric and construction checks have actually run and passed.

## 2. Crucial task separation

The currently integrated MLX anatomy adapter consumes three registered orthographic mesh renders and returns an **anatomical cut plan**. The app expects the exact JSON contract in Section 4. Train this task in its own dataset, with only app-compatible labels.

Panel layout, seam-path planning, allowance offsets, darts, gathers, stitch matching, print layout, and final sewing instructions are valuable future training tasks, but they are **not interchangeable with anatomy-cut examples**. Do not put prose, panel coordinates, sewing instructions, extra JSON properties, multiple task types, or ranking answers into the current adapter's target field. Do not train the cut adapter to emit unsupported data and expect the app to consume it.

Use a separate task identifier and schema for each future task in Section 8. Keep those data in separate JSONL files or train a separate adapter until the application explicitly supports routing, parsing, and validating the task. Reuse trusted app-generated geometric results as labels; never ask an LLM to fabricate precise geometry.

## 3. Data-generation procedure

For every candidate source asset:

1. **Rights and provenance:** Record a non-sensitive asset ID, source category, authorization status, license/provenance where known, and whether images are derived from the mesh. Exclude assets with unclear permission. Do not put personal information, credentials, or unrelated metadata in examples.
2. **Preserve the source:** Keep the original mesh immutable. Record its format, units if known, vertex/face counts, connected-component count, bounds, and validation status in a sidecar manifest, not in the current adapter's target JSON.
3. **Inspect mesh quality:** Detect non-finite vertices, zero-area triangles, invalid indices, disconnected shells, duplicate/near-duplicate vertices, non-manifold edges, open boundaries, inverted normals, extreme thin features, self-intersections where available, and inconsistent units. Do not silently call defective geometry clean. Mark whether the application repaired it and preserve both pre- and post-repair provenance.
4. **Create views from the exact mesh:** Render a consistent front (+Z), side (+X), and top (+Y) orthographic view with the coordinate mapping in Section 4. All views must show the same mesh state, use stable framing, and retain sufficient resolution to see limb roots, necks, wings, tails, ears, horns, fins, and other relevant connections. Do not silently rotate only one view or change the axis mapping. Add a close-up only in a separately specified future task; the current model accepts the registered three-view set.
5. **Establish labels from geometry:** Determine candidate cut planes from the real mesh bounds and visible anatomy. Confirm each label with the actual plane coordinate and the resulting split in the app's mesh splitter. Record a cut only when the plane separates the intended component(s), preserves valid surfaces, and does not create unintended slivers. Do not derive a precise normalized cut position by eyeballing a screenshot.
6. **Create hard negatives and contrastive examples:** Include tempting but wrong cuts, such as a plane through the middle of a head, a plane that misses an appendage root, duplicate cuts, a cut that merges paired limbs into a misleading region label, or a cut that produces a sliver. Keep the correct answer tied to the exact geometry and views. Exclude ambiguous cases when no defensible ground truth exists.
7. **Validate the target:** Parse every target with the app's current decoder and validations. Reject malformed JSON, unsupported keys, invalid ranges, overlong strings, unsupported axes, duplicate/near-duplicate planes, unsupported boundaries, and incorrect negative/positive region orientation.
8. **Separate by underlying asset:** All views, rotations, decimations, repaired versions, remeshes, augmentations, and near-duplicates of one source geometry must remain in a single train, validation, or test partition. Never let a modified copy of a validation/test mesh leak into training.
9. **Track curation:** Save a manifest with asset ID, task/schema version, split, label provenance, validation results, app version or commit, and exclusion reason when rejected. Avoid editing an existing active run's files in place; create a versioned dataset directory for every corpus revision.

## 4. Current MLX anatomy-cut task contract

### Input prompt for each example

Use the following instruction in the `messages[0].content` user text for current cut-plan examples. Keep it semantically consistent; vary only a short task-specific sentence when a deliberate prompt-robustness variant is being tested.

> You are proposing plushie construction boundaries on a known 3D mesh. Plan anatomy-first construction around the head, torso, and appendages. Eyes, nose, mouth, markings, claws, and other surface details are embroidered or attached after sewing; they are not fabric panels.
>
> The three attached images are orthographic renders of the same mesh and are registered to its axes: front looks along +Z (image right is +X, image up is +Y); side looks along +X (image right is -Z, image up is +Y); top looks along +Y (image right is +X, image up is -Z). The mesh coordinate frame is authoritative. Do not assume it is upright or symmetric.
>
> A proposed cut is an axis-aligned plane. `normalizedPosition` is measured from 0 to 1 across the full bounds of that axis; 0.5 is its midpoint. For each cut, report which region lies on the lower-coordinate (negative) side and which lies on the higher-coordinate (positive) side.
>
> Return only clear, useful construction boundaries supported by these views. Prefer the fewest cuts that separate the visible, sewable anatomical components. Do not invent hidden anatomy, diagonal cuts, vertex paths, exact measurements, bounds, geometry, or seams. Do not create arbitrary panels by cutting through broad regions. If evidence is limited, state the uncertainty in `summary` and lower confidence; omit unsupported cuts.
>
> Return one JSON object only, with exactly `summary` and `cuts`. Include 1–9 cuts. Each cut must have exactly `axis`, `normalizedPosition`, `boundary`, `negativeRegion`, `positiveRegion`, and `confidence`. `axis` must be `x`, `y`, or `z`; `normalizedPosition` must be between 0.1 and 0.9; `confidence` must be between 0.55 and 1.0. Use concise stable region names. `summary` must be no more than 300 characters; `boundary` no more than 120 characters; each region no more than 48 characters. Do not use markdown or explanatory text outside the JSON.

### Exact assistant target

Each current-task target must be valid JSON with precisely this shape:

```json
{
  "summary": "Brief evidence-grounded description of the visible anatomy and proposed construction.",
  "cuts": [
    {
      "axis": "z",
      "normalizedPosition": 0.68,
      "boundary": "neck-to-torso boundary",
      "negativeRegion": "torso",
      "positiveRegion": "head",
      "confidence": 0.82
    }
  ]
}
```

The values above illustrate field shape only; they are not a universal label or a recommended cut. Compute positions and region sides from each real mesh's own coordinate bounds. This app's parser also merges same-axis planes within 0.03; the normalized result may contain at most 8 distinct planes, and distinct planes on one axis must be at least 0.03 apart. Generate labels that remain valid after this normalization.

### Labeling rules for anatomy

- Name parts as the mesh supports them: head, neck, torso, muzzle, jaw, ear, horn, crest, wing, arm, forelimb, hand/paw, leg, hindlimb, foot, hoof, tail, fin, flipper, tentacle, antenna, shell, or another concise anatomical term. Use left/right only when the views and coordinate mapping support the side assignment.
- A cut's `boundary` describes a useful joining interface, such as `left forelimb root`, `head-to-neck`, or `tail base`. It is not a proposed stitch path across the full surface.
- The negative and positive region names must follow numeric axis coordinates, not viewer-left/viewer-right. Verify signs against actual mesh bounds and view mapping.
- Separate paired appendages only when their roots can be distinguished and the cut plane creates meaningful independent pieces. If one plane intersects multiple limbs, describe exactly which ones it separates; do not imply that one plane yields independent pieces if the splitter cannot do that.
- For wings, ears, fins, horns, tentacles, and tails, distinguish a thin projection from its root and identify whether the mesh connects it at a visible, useful join. Do not invent a joint where the mesh has a continuous silhouette or ambiguous attachment.
- For shells, armor plates, spikes, manes, feathers, fur tufts, markings, and facial features, do not automatically treat every detail as a separate stuffed component. Recommend separate fabric components only when a plausible sewn join is visible and the geometry supports it; surface applique and embroidery are often better.
- Preserve the character's recognizable silhouette and allow for stuffing access. Do not use a cut as a substitute for a seam required to flatten a closed surface.
- Do not assume bilateral symmetry. Do not copy the left-side cut to the right by reflection unless both sides are visibly and geometrically equivalent.
- Avoid overlapping cuts, cuts closer than 3% of the axis bounds, boundary names longer than 120 characters, region names longer than 48 characters, and cuts outside 0.1–0.9.
- Output at least one supported cut because the current contract does not allow an empty `cuts` array. If the mesh is genuinely unsuitable or the views do not support any safe cut, do not invent one to satisfy the schema: exclude the example from supervised training and report the exclusion in its curation manifest.

## 5. Coverage plan: simple through complex

Build balanced examples across the following dimensions. Use combinatorial coverage, not only one stereotypical upright, symmetric animal.

### Geometry complexity

1. **Very simple:** spheres, capsules, rounded cubes, bean shapes, egg bodies, and a single attached ball or cone. Teach restraint: one or a few meaningful joins, not decorative cuts.
2. **Simple silhouettes:** one head, one torso, two paired limbs, optional tail; separated or fused limbs; broad necks; short legs; large heads; toy-like proportions.
3. **Moderate anatomy:** long necks, snouts, ears, horns, wings, fins, paws, hooves, multiple tail shapes, belly/face patches, layered manes, shells, and asymmetrical accessories.
4. **Complex creatures:** multiple limb pairs, digitigrade or plantigrade legs, branching antlers, tentacles, long serpentine bodies, articulated wings, fins plus limbs, shells attached to torsos, multi-segment tails, and mixed soft/hard-looking anatomy.
5. **Challenging mesh conditions:** posed or rotated meshes, non-uniform scale, odd origins, disconnected shells, fused intersections, open scans, thin surfaces, low-poly or dense tessellation, small details, topology defects, and ambiguous silhouettes. Label what is still visible; flag unsupported inference instead of making up structure.

### Form and style variation

Include original and authorized designs across:

- Mammals: dog-like, cat-like, small pets, livestock, wild quadrupeds, rodents, bats, and imaginative furred species.
- Birds and flying creatures: short or long beaks, wings, tails, crests, feet, and nonstandard wing counts.
- Aquatic forms: fish, cetacean-like silhouettes, amphibians, flippers, fins, gills, and aquatic fantasy creatures.
- Reptilian and prehistoric forms: long bodies, shells, crests, horns, tails, short limbs, and varied stance.
- Invertebrate and alien-like forms: insects, arachnid-like silhouettes, many legs, antennae, segmented bodies, soft tentacles, and unusual body plans.
- Humanoid and stylized bodies: chibi proportions, oversized heads, short or long limbs, costumes represented in the mesh, and original mascots.
- Cryptid and folklore-inspired forms: unusual combinations of familiar anatomy, deliberately ambiguous silhouettes, extra appendages, and asymmetry.
- Pets and real-animal scans: varied poses, fur geometry, collars or accessories, partial scans, and realistic asymmetry. Exclude identifying owner information.
- Broad visual styles: smooth, blocky, low-poly, plush-like, cel-shaded appearance, comic-like proportions, or realistic surface texture. Style does not establish anatomy.

Keep all character and creature examples original or authorized. Do not prompt the model to reproduce named commercial characters, distinctive protected costumes, signature markings, logos, or a specific franchise's look. If a user supplies a mesh for processing, train on geometry-derived, task-relevant labels without expanding it into unprovided protected expression.

### Variation and robustness

For the same source geometry, controlled view transformations can be useful, but all derivatives stay in the same data partition. Include mirrored and non-mirrored anatomy, rotated coordinate frames, non-centered origins, scale changes, low-resolution renders, mild occlusion, and differing but documented tessellation. Always regenerate the registered orthographic views and exact labels after transformations. Never relabel positions by copying values from the original mesh.

Balance easy, medium, and difficult samples. Include false-friend examples where a visual bulge is not a separate appendage, limbs overlap in projection, a far-side appendage is partly occluded, or a continuous curved tail has no obvious joint. Include accurate no-op construction cases only in a separate task that supports them; do not insert an empty current-task cut plan.

## 6. Sewing-aware construction principles

Use these as reasoning and future-task label criteria. The current cut task should encode only supported anatomy and axis-aligned planes; do not add them as extra output keys.

- A component boundary must permit components to be sewn back together without losing intended orientation, laterality, or silhouette. Consider matching notches, seam endpoints, grain direction where known, and a clear assembly order.
- Keep small appendages and narrow roots constructible. A tiny horn, paw, toe, ear tip, claw, or tail tip may be better as an inset, applique, gusset, or simplified shape than a separate stuffed tube. Do not create a component that is too narrow to turn, stitch, or stuff at the chosen scale.
- For a closed 3D component, do not assume one planar outline is enough. A sphere-like head or torso normally needs multiple panels, darts, or a deliberately opened seam. Determine this through the supported flattening pipeline, not by guessing from the anatomy-cut views.
- Choose seam allowance from an explicit user setting or a named common option. The app currently exposes 6 mm, 1/4 in, 3/8 in, 1 cm, 1/2 in, 5/8 in, and 1.5 cm, with 1/4 in as its default. Never silently mix inches and millimeters; store physical units and convert once.
- Keep the stitching line and cut line distinct. A seam allowance is a parallel offset of the stitching curve, not a scale factor or an arbitrary border. Concave corners, narrow channels, and tight curves may make an offset invalid; reject or explicitly flag those cases rather than self-intersecting the pattern.
- Sewing techniques are material- and geometry-dependent:
  - **Darts** remove excess area from curved regions such as a dome, muzzle, rump, or paw. Record dart legs, apex, intake, and closure direction only when produced or verified by the pattern solver.
  - **Ease** joins slightly mismatched stitch lengths over a controlled span. Keep the easing zone and direction explicit.
  - **Gathering** distributes larger excess into a shorter edge and is unsuitable for every fabric or tiny detail. Specify the target edge, gather ratio, and control marks only from measured edge data.
  - **Gussets/insets** create volume or transition shapes at heads, muzzles, limbs, paws, and bodies. Use them only when their seams and panel boundaries are defined.
  - **Applique/embroidery** is often appropriate for eyes, nose, mouth, spots, scales, belly patches, and other surface decoration; it is not a stuffed anatomical panel.
  - **Openings and closures** must leave a reachable path for turning, stuffing, and closing. Identify the closure seam separately from a component join.
  - Notches, matching marks, mirrored pairs, nap direction, pile direction, and fabric stretch direction must be tracked for real construction data.
- If intended fabric, stretch, nap, pile, thickness, or plush scale is unknown, mark it unknown. Do not claim a pattern accounts for fabric behavior without that input.
- Do not use human or pet measurements inferred from an image. Plush dimensions require an explicit scale or user-provided finished height.

## 7. Data balance and split strategy

Start with a broad, reliable corpus and add complexity without allowing synthetic regularity to dominate. For an expanded anatomy corpus, target a balanced mix such as:

- 20% simple forms and basic joins.
- 30% common animal-like and stylized character anatomy.
- 25% varied or multi-appendage creatures.
- 15% difficult pose, asymmetry, scan, and topology conditions.
- 10% ambiguity, hard negatives, failure analysis, and calibrated uncertainty.

These are starting proportions, not hard requirements. Adjust based on held-out per-category performance. Ensure that each broad morphology and difficulty level occurs in validation and test, while keeping source geometry families disjoint. Do not oversample rare categories by generating near-identical meshes. Track counts by morphology, complexity, pose, topology condition, cut axis, number of cuts, and confidence band.

Use a versioned corpus directory. Preserve the active `anatomy3` dataset and any in-progress run. Create a new named dataset revision rather than mutating training inputs under a running process. Store `train.jsonl`, `valid.jsonl`, and `test.jsonl` separately and add a manifest and deterministic build seed. Validation and test sets must be curated with the same rigor as training and must never be used for prompt tuning without recording that change.

## 8. Future tasks: separate schemas and labels

Add these tasks only as separately versioned examples and only when the corresponding application pipeline can parse, validate, and use the output.

### A. Mesh inspection and preparation

Potential outputs: input mesh format; coordinate bounds and units; connected components; topology diagnostics; likely orientation ambiguity; whether an operation is recommended; an explanation of limitations. Exact counts and diagnoses must come from mesh-analysis tools. Never invent statistics from an image. A model may prioritize a repair workflow, but the deterministic mesh validator must confirm the result.

### B. Anatomy graph and component assembly

Represent components as stable IDs with parent/child or attachment relationships, laterality, visible evidence, uncertainty, and intended join labels. Ground each relationship in the mesh. Include assembly dependencies, but distinguish visible attachment from a guessed anatomical joint. Validate that the graph corresponds to actual split components and that every required join has a compatible partner.

### C. Sewable 2D panel plan

Store panel IDs, source component IDs, panel geometry reference IDs, pair/mirror relationships, grain or nap direction when known, stitching-line references, cut-line references, seam-allowance value and unit, darts, gathers/easing ranges, notches, closure opening, and intended assembly order. A model must not emit raw coordinates unless those coordinates are produced by a geometry tool and constrained to its documented coordinate frame. Store solver output separately from natural-language rationale.

### D. Flattening choice or seam candidate ranking

When ranking app-generated candidates, include only actual candidate IDs and their measured solver metrics. Train the model to rank the supplied candidates for a stated objective (stitchability, low distortion, fewer panels, fabric savings, or user priority), not to invent candidates. The chosen IDs must be an exact permutation of the candidate set, with no extras or omissions. Keep user priorities explicit and retain valid trade-offs rather than fabricating a single universal best.

### E. Construction instructions and QA

Generate concise, ordered construction steps from validated panels and assembly data. Include right/wrong sides, matching notches, dart closure, easing/gathering, turning, stuffing order, closure seam, and any mirrored components. Mark operations that require a human decision. Each instruction must reference real panel IDs and verified sewing facts. Add a final checklist for seam allowance, stitch-line pairing, panel count, scale, calibration, and assembly completeness.

For any future task containing UV layouts, pattern offsets, or topology changes, the application must run its Chain-of-Verification first: calculate source 3D surface area and resulting 2D island area with consistent units and triangulation, reject degenerate/non-finite geometry, and throw rather than report success when relative area delta exceeds 5%. An LLM label is not a substitute for this check.

## 9. Target quality and exclusion rules

Accept an anatomy example only when all of the following hold:

- The three images are registered views of the exact labeled mesh.
- Every cut is geometrically derived, axis-correct, in bounds, and produces its intended split in the app.
- The cut does not create accidental slivers, degenerate geometry, or an obviously unusable component.
- Region names accurately describe lower- and higher-coordinate sides.
- The number of cuts is minimal for the visible construction intent; arbitrary segmentation is not rewarded.
- The JSON parses and passes the current app's exact decoder and plan normalizer.
- Label confidence reflects evidence, not annotator certainty or a desire to avoid abstention.
- The summary is concise, factual, and within schema limits.

Reject or quarantine examples with disputed anatomy, guessed hidden geometry, invalid or ambiguous orientation, corrupted images, uncertain provenance, mislabeled signs, nonseparating cuts, duplicated planes, impossible components, or labels generated only from another model. Keep a rejection reason in the manifest; do not silently delete hard cases and then claim broad coverage.

Quality-review samples across every complexity tier. Use a second independent review for a representative fraction and all high-risk complex cases. Compare against geometric checks rather than judging only by plausible wording. Keep disagreements as unresolved data until adjudicated; do not average two incompatible cut plans.

## 10. Training, evaluation, and iteration protocol

Do not treat low token loss or high token accuracy as proof of useful pattern plans. Evaluate both output validity and downstream construction:

1. **Protocol validity:** valid JSON; exact keys; allowed ranges; parser acceptance; normalized planes valid and distinct.
2. **Cut detection:** per-axis precision/recall/F1 with one-to-one matching and a documented tolerance (start at 0.05 normalized units); report missed and extra cuts separately.
3. **Whole-plan quality:** exact plan rate; correct side labels; region-label accuracy; confidence calibration; minimum useful cut count; rate of unusable or over-segmented plans.
4. **Geometric success:** run the app splitter on every eligible prediction; count nonseparating planes, unintended components, slivers, invalid topology, and failures.
5. **Construction quality:** for future panel tasks, measure verified area delta, local distortion, flipped triangles, self-overlap, stitch-length mismatch, seam-allowance validity, panel count, and assembly-graph completeness.
6. **Stratified performance:** break down by morphology, complexity, pose, asymmetry, topology condition, view resolution, number of cuts, and confidence band. Report sample counts; do not hide weak subgroups behind one aggregate.
7. **Generalization:** reserve unseen geometry families and asset sources. Include real held-out user-authorized meshes in an evaluation set, not just generated primitives.
8. **Human review:** inspect representative correct, incorrect, ambiguous, and high-confidence-wrong outputs. Convert verified failure modes into targeted data; avoid blindly reinforcing model-generated errors.
9. **Operational safety:** run training and validation in separate versioned output/log locations; do not overwrite a mounted dataset used by an active trainer; retain prior adapters and evaluation logs.

After each training run, report dataset revision and split counts, training configuration, validation loss/accuracy, JSON/app-valid rate, cut precision/recall, exact-plan rate, downstream split success, subgroup failures, and next data changes. State clearly what has not been measured. Do not call a model "trained for pattern generation" merely because it predicts anatomy cuts.

## 11. Instructions for the data-generation model

When asked to generate examples:

1. First state which task and schema version each example belongs to.
2. Generate current anatomy-cut examples only in the exact format in Section 4.
3. Do not invent unseen mesh properties or exact plane locations. If geometry-derived labels are not available, produce a curation specification or mark the item for exclusion rather than fabricate a training target.
4. Vary anatomy, orientation, proportions, topology, and difficulty. Avoid repeating a small set of stock creature templates.
5. Include both common cases and instructive failure cases, but do not put incorrect labels into positive targets.
6. Return machine-readable JSONL only when explicitly asked for dataset rows. Keep analysis, manifests, and rejection reasons in separate files.
7. Never mix future panel/assembly schemas into the current cut adapter's JSONL.
8. Do not overwrite or modify an active dataset or adapter. Write a new versioned output and report the exact destination.
9. Do not claim training has run, labels have been verified, or a physical sewing pattern is ready until those steps have actually completed.

