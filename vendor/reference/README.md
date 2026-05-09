# reference/

Vendored copies of upstream materials that the application or its
documentation rely on.

## What lives here

- `robotis-op-series-data/` — checked-in PDFs from
  [`ROBOTIS-GIT/ROBOTIS-OP-Series-Data`](https://github.com/ROBOTIS-GIT/ROBOTIS-OP-Series-Data),
  specifically the wiring manual, fabrication manual, assembly manual,
  and sub-controller control-table references. **Not yet committed**;
  download from the upstream repo on first setup.
- `upstream-headers/` — verbatim copies of `Framework/include/CM730.h`,
  `MX28.h`, `JointData.h`, and `FSR.h` from the
  [`darwinop-ens/darwin-op`](https://github.com/darwinop-ens/darwin-op)
  mirror, used as the authoritative source for register addresses and
  joint IDs. Replace whenever the framework version on the robot is
  updated.

## Why vendor?

`emanual.robotis.com` and `support.robotis.com` block automated
fetches; the upstream PDFs occasionally disappear or move. A snapshot
in this directory ensures the build is reproducible offline.
