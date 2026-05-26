[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# Schnizo

This branch hosts the **Schnizo core** — a simple RISC-V integer core that supports **hardware loops** (`frep`) and **out-of-order execution** within those hardware loops via a reservation-station-based scoreboard. The hardware-loop mechanism allows the core to issue independent instructions from the loop body while waiting for results, effectively hiding latency and improving throughput without a full out-of-order pipeline.

Example tests exercising the hardware-loop and chaining features can be found in [sw/tests/src/](sw/tests/src/), including:

- [frep1d.c](sw/tests/src/frep1d.c) — basic single-loop smoke test
- [frep2d_1.c](sw/tests/src/frep2d_1.c) — nested hardware loops
- [frep.c](sw/tests/src/frep.c) — three levels of nested loops with independent iterations
- [gemm_frep.c](sw/tests/src/gemm_frep.c) — matrix multiply using nested hardware loops

## Experimental SIMD Support (this branch)

This branch adds experimental **SIMD support** using the [RISC-V Vector (RVV) extension](https://github.com/riscv/riscv-v-spec) encoding, backed by the hardware elements of [Spatz](https://github.com/jogut445/schnizo) (see the linked branch for the VFU microarchitecture).

The vector functional unit (`schnizo_vfu.sv`, `schnizo_vlsu.sv`) is integrated into the Schnizo pipeline and dispatched through the existing hardware-loop and scoreboard infrastructure, enabling **vectorized loops with out-of-order vector execution**.

> **Important:** This is **not a compliant RVV implementation.** The hardware reuses the RVV instruction encoding as a convenient ISA surface, but only implements a subset of the specification and deliberately deviates from the full standard in key ways:
> - Only **fixed 256-bit SIMD** operation is supported. There is no variable-length vector model — `vl` must always match the full 256-bit width for the chosen element type.
> - Some instructions of the RVV instruction set are **not implemented**. Unimplemented instructions will produce undefined behavior.
> - Features such as fractional LMUL, tail/mask agnostic policies beyond `ta/ma`, and segment load/store are not supported.
> **Key Feature:** With sufficient loop unrolling inside `frep`, the VFU can sustain **one `vfmacc` per cycle** — 100% utilization. The 8-row-unrolled GEMM kernel in [vfu_test_gemm_8x_frep.c](sw/tests/src/vfu_test_gemm_8x_frep.c) demonstrates this: by interleaving eight independent accumulator chains within a single `frep.o` body, the out-of-order scoreboard keeps the VFU fully occupied across all iterations.

Example tests:

- [vfu_test_vec_instr_1_int_vv.c](sw/tests/src/vfu_test_vec_instr_1_int_vv.c) — integer vector-vector operations
- [vfu_test_vec_instr_4_fp_vv.c](sw/tests/src/vfu_test_vec_instr_4_fp_vv.c) — floating-point vector operations
- [vfu_test_axpy_frep_f32.c](sw/tests/src/vfu_test_axpy_frep_f32.c) — AXPY kernel using hardware loops + RVV

## Getting Started

The repository structure and build system are modelled closely on the [Snitch Cluster](https://github.com/pulp-platform/snitch_cluster) — refer to that project's [documentation](https://pulp-platform.github.io/snitch_cluster) for general setup, tool requirements, and simulation flow. The `make` targets and `cfg/` layout follow the same conventions.

## SIMD Programmability

The vector unit operates exclusively on **256-bit wide vectors**. There is no support for shorter or wider configurations — the `vtype` must be set accordingly before issuing any vector instruction.

Always configure the vector length with `vsetvli` before use. The element width (`e32` for 32-bit, `e64` for 64-bit) determines the number of elements per vector:

```c
// 8 x 32-bit elements = 256 bits
asm volatile("vsetvli zero, %0, e32, m1, ta, ma" : : "r"(8));

// 4 x 64-bit elements = 256 bits
asm volatile("vsetvli zero, %0, e64, m1, ta, ma" : : "r"(4));
```

A complete example — 32-element AXPY using hardware loops over 256-bit RVV vectors:

```c
#define VL 8  // 8 x f32 = 256 bits

asm volatile("vsetvli zero, %0, e32, m1, ta, ma" : : "r"(VL));

asm volatile(
    "frep.o %[iter], 8, 0, 0       \n"
    "vle32.v  v0, (%[px])          \n"   // load x
    "vle32.v  v1, (%[py])          \n"   // load y
    "vfmul.vf v2, v0, %[alpha]     \n"   // v2 = alpha * x
    "vfadd.vv v3, v2, v1           \n"   // v3 = alpha*x + y
    "vse32.v  v3, (%[pz])          \n"   // store result
    "addi %[px], %[px], %[sz]      \n"
    "addi %[py], %[py], %[sz]      \n"
    "addi %[pz], %[pz], %[sz]      \n"
    : [px] "+r"(px), [py] "+r"(py), [pz] "+r"(pz)
    : [iter] "r"(n_iter - 1), [alpha] "f"(alpha), [sz] "i"(VL * 4)
    : "v0", "v1", "v2", "v3");
```

The key constraints to keep in mind:

- `vsetvli` must appear before every vector code region — the VFU does not infer the vector length.
- Only 256-bit operation is supported (`m1` with matching element count). Smaller or larger `vl` values will produce incorrect results.
- Vector operations are issued through the hardware-loop dispatcher; using them outside an `frep` loop is possible but loses the out-of-order benefit.

## License

The following files are released under Solderpad v0.51 (`SHL-0.51`) — see `hw/LICENSE`:

- `hw/`

The `sw/deps` directory references submodules that come with their own licenses. See the respective folders for details.

All other files are released under Apache License 2.0 (`Apache-2.0`) — see `LICENSE`.
