// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Schnizo SIMD AXPY kernels: z = a*x + y
//
// Schnizo has a fixed 256-bit vector register width.  With e64 (double) the
// vector length is always 4 elements.  There is no strip-mining loop ? one
// vle64.v / vse64.v operates on exactly 4 doubles at a time.  A single
// vsetvli is issued at kernel entry to program the hardware; it must not be
// repeated inside loops.
//
// Preconditions for the frep variant:
//   n must be divisible by (SCHNIZO_VL_F64 * num_cores).
// The loop variant accepts any n (rounds down per core).

#pragma once

#include "snrt.h"
#include <stdint.h>

// Number of f64 elements in one 256-bit vector register.
#define SCHNIZO_VL_F64    4
// Byte stride to advance a pointer by one full vector.
#define SCHNIZO_VEC_BYTES (SCHNIZO_VL_F64 * (int)sizeof(double))

// ---------------------------------------------------------------------------
// axpy_simd_frep
//   Fastest path: frep unrolls the entire element loop.
//   n must be divisible by SCHNIZO_VL_F64 * num_cores.
// ---------------------------------------------------------------------------
static inline void axpy_simd_frep(uint32_t n, double a, double *x, double *y,
                                  double *z) {
    int core_idx  = snrt_cluster_core_idx();
    int num_cores = snrt_cluster_compute_core_num();
    int frac  = n / num_cores;           // contiguous doubles per core
    int n_vec = frac / SCHNIZO_VL_F64;   // vector iterations per core

    double *px = x + core_idx * frac;
    double *py = y + core_idx * frac;
    double *pz = z + core_idx * frac;

    // Program vl once; schnizo ignores avl and always uses the full 256-bit width.
    asm volatile("vsetvli zero, %0, e64, m1, ta, ma" ::"r"(SCHNIZO_VL_F64));

    snrt_mcycle();
    asm volatile(
        // Repeat the following 7-instruction body n_vec times.
        "frep.o  %[nv],   7, 0, 0        \n"
        "vle64.v  v0,    (%[px])         \n"  // x chunk -> v0
        "vle64.v  v8,    (%[py])         \n"  // y chunk -> v8
        "add      %[px], %[px], %[inc]   \n"
        "add      %[py], %[py], %[inc]   \n"
        "vfmacc.vf v8,   %[a],  v0       \n"  // v8 = a*v0 + v8
        "vse64.v  v8,    (%[pz])         \n"  // store result
        "add      %[pz], %[pz], %[inc]   \n"
        : [px] "+r"(px), [py] "+r"(py), [pz] "+r"(pz)
        : [nv] "r"(n_vec - 1), [a] "f"(a), [inc] "i"(SCHNIZO_VEC_BYTES)
        : "memory");
    snrt_mcycle();
    asm volatile("fence");
}

// ---------------------------------------------------------------------------
// axpy_simd_loop
//   Reference path: C for-loop drives the vector body.
//   Handles any frac (processes floor(frac/4)*4 elements per core).
// ---------------------------------------------------------------------------
static inline void axpy_simd_loop(uint32_t n, double a, double *x, double *y,
                                  double *z) {
    int core_idx  = snrt_cluster_core_idx();
    int num_cores = snrt_cluster_compute_core_num();
    int frac      = n / num_cores;

    double *px = x + core_idx * frac;
    double *py = y + core_idx * frac;
    double *pz = z + core_idx * frac;
    int rem    = frac;

    asm volatile("vsetvli zero, %0, e64, m1, ta, ma" ::"r"(SCHNIZO_VL_F64));

    snrt_mcycle();
    for (; rem >= SCHNIZO_VL_F64; rem -= SCHNIZO_VL_F64) {
        asm volatile("vle64.v  v0, (%0)" ::"r"(px));
        asm volatile("vle64.v  v8, (%0)" ::"r"(py));
        asm volatile("vfmacc.vf v8, %0, v0" ::"f"(a));
        asm volatile("vse64.v  v8, (%0)" ::"r"(pz));
        px += SCHNIZO_VL_F64;
        py += SCHNIZO_VL_F64;
        pz += SCHNIZO_VL_F64;
    }
    snrt_mcycle();
    asm volatile("fence");
}
