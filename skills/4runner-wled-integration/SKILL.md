---
name: 4runner-wled-integration
description: "Maintain the 2005 V8 4Runner single-board RGBW controller, its WLED firmware and native iOS controls. Use for this project's PCB/CAD, JLCPCB assembly costs, six-wire harness, CAN relay, voltage sensing or WLED interface changes."
---

# 4Runner WLED Integration

Preserve the approved lighting product while making the requested change. This is project-specific guidance, not a requirement for unrelated WLED builds.

## Find the current source

The repository is `IsaiahDupree/4runner-vehicle-health-os`. Resolve this skill's symlink to its real directory: the versioned copy lives at `skills/4runner-wled-integration/` inside the project. Read that checkout's `AGENTS.md`, Git status and [saved design decisions](../../ios/Lighting/DESIGN-DECISIONS.md). Select the intended worktree before editing; the repository name alone does not identify its active revision.

The references record accepted work on **2026-11-21**, including implementation commits `f81e2b2`, `ff540e4`, `ffdb308` and handoff `4a6c924`. Reconcile them with newer accepted source and evidence; do not treat a dated stock capture, test count or configuration as a permanent fact.

Read only the reference relevant to the assignment:

- [WLED controls and integration lessons](references/wled-and-ios.md): native UI, controller API, verified CAN relay, input/voltage behavior.
- [PCB, enclosure and JLCPCB lessons](references/pcb-cad-jlcpcb.md): connector/wire map, factory assembly, cost calculation, real-component CAD and fit checks.
- [Verification and delivery lessons](references/verification-delivery.md): authoritative evidence, regression commands, bounded Apple builds, signing and hardware acceptance.

## Preserve the product decisions

- Use one integrated PCB. The six-pin Toyota inline harness is the sole power inlet. Preserve all six conductors and their pass-through; unknown/reserve wires remain individually isolated. No extra 12 V supply or local CAN adapter is part of this design.
- Use one analog RGBW output zone, segment 0 / Whole strip. WLED's three color slots are effect colors. Independent physical sections or addressable animations require an explicitly requested output/LED redesign.
- Follow WLED's Colors / Effects / Segments / Presets structure: circular color wheel, target dropdown and bold, direct controls. Use controller-stored presets. Keep the approved CAN relay, voltage, TAIL/DIM and connection settings in Config. Vehicle pictures, promotional layouts, unrelated UI references and phone-only scenes were rejected.
- Supply sensing measures fused, switched ACC at the box. ACC-off resting battery measurement and battery-health claims are unavailable through this circuit.
- Keep CAN data on the existing verified gateway → foreground iPhone → authenticated controller Wi-Fi path. Preserve units, ECU identity, session/sequence and freshness. Do not invent Toyota signal meanings, arbitrary CAN transmission or a resident Android relay.
- Preserve the factory-assembled goal. Cost reduction must include the actual assembly method, harness, enclosure, programming and QA; component material alone is not a delivered product price.

## Work and verification boundaries

Change only the requested layer and its necessary dependencies. Reuse the existing validators and native sources rather than introducing parallel implementations. Keep old accepted revision kits separate from new outputs.

Use source-linked measurements and actual component specifications. Label estimated geometry, conditional electrical screens, local UI previews and unavailable telemetry. Verify the exported populated PCB against the enclosure; an attractive concept image does not establish fit.

Heavy CAD, routing, firmware cross-compilation, rendering, slicing and simulation run through authenticated typed **Orion** jobs. Mac work is source/Git/orchestration, lightweight single-process checks and bounded Apple-only builds/signing. Missing Orion prerequisites require a concrete blocker report, not a heavy Mac/cloud fallback. This skill adds no daemon, provider, dependency installer or automatic job launcher; see [resource policy](resource-policy.json).

Run checks appropriate to the changed layer plus the repository's required pre-commit checks. Record the exact source revision, commands, results and artifact hashes. Distinguish source review, digital fit, successful compilation, signature validation, physical installation and vehicle qualification.

Save new decisions with their evidence in the project and update these references when a demonstrated lesson changes future work. Commit/push completed work under the owner's repository policy, keeping GitHub Actions and automatic deployments disabled. Skill invocation does not authorize purchases, manufacturing orders, external publication or cloud compute.
