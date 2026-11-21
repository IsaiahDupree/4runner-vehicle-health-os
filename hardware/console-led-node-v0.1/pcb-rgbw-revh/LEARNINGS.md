# PCB, assembly and enclosure lessons

- Keep the complete product scope separate from a PCBA quote. Programming,
  fuses, harnesses, wire clamping, inserts, enclosure assembly and functional
  testing must be in the supplier scope. Include every through-hole component
  in BOM and CPL; an SMT-only price is not a finished-board price.
- Capture JLCPCB stock and price with date, source URL and part code. Reuse one
  stocked connector SKU when its wire, footprint and assembly requirements fit.
  Six identical two-position blocks provide twelve positions with one new
  Extended SKU. Component material cost excludes assembly and setup charges.
- Reconcile exact manufacturer identities across schematic, board properties,
  BOM and CPL. The inherited generic 3568 fuse-holder field needed correction
  to the factory's exact 3568-10 SKU; this was checked without changing routes.
- Board-space savings can make wiring impractical. Reserve actual wire entry,
  jacket split, bend radius and screwdriver space before freezing placement.
  Staggering the two terminal banks by 3 mm and moving D7 created an uncrossed
  fanout without enlarging the outer enclosure or changing the power layout.
- Sampled wire curves help choose candidate routes. Accept them only after
  checking the exact swept solids against each other and the exported board,
  enclosure, tools and fasteners. The final 1.6 mm OD screen has at least
  0.2767 mm surface separation between conductors.
- Derive driver approach height from the exported terminal body. The native
  PCB model includes a small placement offset beyond the nominal package height.
  Cover the full terminal top when the manufacturer's screw-axis offset is
  unspecified, and preserve lid removal as the required service state.
- Use the manufacturer's wire gauge and strip length. A gauge number does not
  determine insulation diameter: the prior thick-wall wire estimate does not
  fit this 1.6 mm OD screen. TE 55A0111-20-* is a 1.27 mm nominal individual-core
  reference; the complete outer-jacketed cable remains a supplier/first-article
  decision. Check upstream fuse coordination before approving a branch gauge.
- Keep all six Toyota conductors registered. The two reserve terminals are
  electrically isolated and never tied to ground or given invented functions.
- Preserve the local eFuse return island, PowerPAD thermal vias and unaffected
  copper. Give each router width class a unique name, then audit actual routed
  widths, isolation, ERC, DRC and schematic parity.
- Build printed bearing rails under the terminal banks and check every insert,
  screw, washer, wire and tool against reopened native geometry. A supports-off
  slice is useful print evidence; it does not prove physical fit, vibration,
  sealing, heat resistance or electrical qualification.
- Keep source and artifact hashes. Preserve native byte hashes separately when
  normalizing text line endings for Git. Run heavy geometry, slicing and rendering
  through bounded authenticated Orion jobs; retain local checks and keep GitHub
  Actions disabled.
