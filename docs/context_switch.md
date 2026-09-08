This file introduces this fork's SRAM-backed context-switch extension and its current limits. It maps the implementation to its source files; reproducible FPGA builds and application tests live in the companion zynq-parrot repository.

# Software-controlled contexts

The accepted PYNQ configuration multiplexes four logical integer contexts onto
two resident register banks and one shared pipeline. A context is not another
core or an independently scheduled Linux task.

## Read the implementation

- `bp_be/src/v/bp_be_context_mem.sv`: private synchronous integer backing RAM;
  per-register valid bits and remote-write priority define the stored image.
- `bp_be/src/v/bp_be_regfile_mt.sv`: resident operand storage, FPGA collision
  bypass, and wide-line installation from the backing image.
- `bp_be/src/v/bp_be_csr_wrapper_mt.sv`: banked control state and retirement
  ownership; restored replay PCs must belong to the target context.
- `bp_be/src/v/bp_be_checker/bp_be_scheduler.sv`: logical/physical identity,
  issue suppression, and cancellation when an older event defeats a switch.
- `bp_common/src/include/bp_common_rv64_csr_defines.svh`: CSR addresses,
  including the nonvirtualized physical-cycle counter at `0xCC0`.

The prototype exposes context switching/readback at `0x800`, PC seeding at
`0x801`, and remote register seeding at `0x802`. See the companion repository's
`linux-tests/ctxtsw_user_tiny.c` for an executable encoding example. Keep detailed
protocol rationale next to the affected RTL rather than in another dated plan.

## Accepted scope

The earlier FPGA-accepted RTL `6c97bcc0a` includes the register-target writeback fix and
passes Linux boot, a cooperating user-mode C handoff 0→2→0 with a target
syscall and register restoration, and the physical overhead benchmark. The
companion repository's `CURRENT_CHECKOUT.md` retains exact bitstream, payload,
timing, and benchmark identities.

The current RTL endpoint `aad56bd92` adds first-seed resident CSR initialization
(`83fc32d29`) and preserves register-bank ownership during FE refill and issue
queue replay. It passes local traced resident/nonresident regressions and has
completed a routed PYNQ-Z2 build. On September 8, 2026, that exact image passed
a shell-launched Linux benchmark with resident 0↔1 and nonresident 0↔2 rings,
private/restored register checks, and a target-context getpid syscall. The first
resident warm-up also checks initialization; every subsequent trial reseeds and
checks completion. The executable returned zero to a usable shell, then Linux
powered off through `CORE[0] PASS`. Evidence and exact image/ELF hashes are in
the companion repository's `logs/linux-resident-shell-20260908/` and
`CURRENT_CHECKOUT.md`; earlier local reproductions remain in
`logs/resident-csr-init-20260907/`.

Ordinary FP execution is retained; complete nonresident FP context preservation
is not part of the accepted FPGA endpoint. General Linux task scheduling,
untrusted-context permissions, arbitrary process lifecycle behavior, and full
cross-address-space isolation are not demonstrated by this test.

Use this demonstration once per fresh overlay/Linux boot: Linux does not reclaim
the extra context state across process exit. This acceptance does not qualify
cross-privilege or differing-SATP/ASID reseeding.

The fork's `master` integrates the accepted resident fixes and verified cleanup.
The companion repository selects its RTL
through the nested checkout and records validation separately; detailed pre-integration history remains at
tag `archive/pre-review-series-20260906`. This integration does not incorporate
the separate upstream changes formerly tracked on the fork's old `master`.
