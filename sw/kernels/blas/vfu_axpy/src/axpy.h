// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Schnizo SIMD-only AXPY kernels: z = a*x + y (fp64, VL=4)
//
// Fixed 256-bit vector width: VL=4 doubles per register (e64, m1).
// n must be divisible by VL * num_cores for axpy_simd_frep.
// axpy_simd_loop handles any n (rounds down to nearest VL multiple per core).

#include "args.h"
#include "snrt.h"

#define SCHNIZO_VL_F64 4
#define SCHNIZO_VEC_BYTES (SCHNIZO_VL_F64 * (int)sizeof(double))

#define BANK_ALIGNMENT 8
#define TCDM_ALIGNMENT (32 * BANK_ALIGNMENT)
#define ALIGN_UP(addr, size) (((addr) + (size)-1) & ~((size)-1))
#define ALIGN_UP_TCDM(addr) ALIGN_UP(addr, TCDM_ALIGNMENT)

// ---------------------------------------------------------------------------
// axpy_simd_frep - frep drives the entire vector loop (fastest path).
// Precondition: n divisible by SCHNIZO_VL_F64 * num_cores.
// ---------------------------------------------------------------------------
static inline void axpy_simd_frep(uint32_t n, double a, double *x, double *y,
                                  double *z) {
    int core_idx = snrt_cluster_core_idx();
    int num_cores = snrt_cluster_compute_core_num();
    int frac = n / num_cores;
    int n_vec = frac / SCHNIZO_VL_F64;

    double *px = x + core_idx * frac;
    double *py = y + core_idx * frac;
    double *pz = z + core_idx * frac;

    asm volatile("vsetvli zero, %0, e64, m1, ta, ma" ::"r"(SCHNIZO_VL_F64));

    snrt_mcycle();
    asm volatile(
        "frep.o   %[nv], 8, 0, 0        \n"
        "vle64.v  v0,    (%[px])        \n"
        "vle64.v  v8,    (%[py])        \n"
        "add      %[px], %[px], %[inc]  \n"
        "add      %[py], %[py], %[inc]  \n"
        "vfmul.vf v16,   v0,    %[a]    \n"  // v16 = a * x
        "vfadd.vv v24,   v16,   v8      \n"  // v24 = a*x + y
        "vse64.v  v24,   (%[pz])        \n"
        "add      %[pz], %[pz], %[inc]  \n"
        : [ px ] "+r"(px), [ py ] "+r"(py), [ pz ] "+r"(pz)
        : [ nv ] "r"(n_vec - 1), [ a ] "f"(a), [ inc ] "i"(SCHNIZO_VEC_BYTES)
        : "v0", "v8", "v16", "v24", "memory");
    snrt_mcycle();
    asm volatile("fence");
}

// ---------------------------------------------------------------------------
// axpy_simd_loop - C loop drives the vector body (handles any frac).
// Processes floor(frac/VL)*VL elements per core.
// ---------------------------------------------------------------------------
static inline void axpy_simd_loop(uint32_t n, double a, double *x, double *y,
                                  double *z) {
    int core_idx = snrt_cluster_core_idx();
    int num_cores = snrt_cluster_compute_core_num();
    int frac = n / num_cores;

    double *px = x + core_idx * frac;
    double *py = y + core_idx * frac;
    double *pz = z + core_idx * frac;
    int rem = frac;

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

// ---------------------------------------------------------------------------
// axpy_job - DMA tiling harness; calls args->funcptr for compute.
// ---------------------------------------------------------------------------
static inline void axpy_job(axpy_args_t *args) {
    snrt_mcycle();
    uint32_t frac, offset, size;
    uint64_t local_x0_addr, local_y0_addr, local_z0_addr, local_x1_addr,
        local_y1_addr, local_z1_addr;
    double *local_x[2];
    double *local_y[2];
    double *local_z[2];
    double *remote_x, *remote_y, *remote_z;
    uint32_t iterations, i, i_dma_in, i_compute, i_dma_out, buff_idx;

#ifndef JOB_ARGS_PRELOADED
    axpy_args_t *local_args = (axpy_args_t *)snrt_l1_next();
    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(local_args, args, sizeof(axpy_args_t));
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();
    args = local_args;
#endif

    frac = args->n / args->n_tiles;
    size = frac * sizeof(double);

    uint32_t double_buffer = args->double_buffer;

    local_x0_addr = ALIGN_UP_TCDM((uint64_t)args + sizeof(axpy_args_t));
    local_y0_addr = ALIGN_UP_TCDM(local_x0_addr + size) + 8 * BANK_ALIGNMENT;
    local_z0_addr = ALIGN_UP_TCDM(local_y0_addr + size) + 16 * BANK_ALIGNMENT;
    local_x[0] = (double *)local_x0_addr;
    local_y[0] = (double *)local_y0_addr;
    local_z[0] = (double *)local_z0_addr;
    if (double_buffer) {
        local_x1_addr = ALIGN_UP_TCDM(local_z0_addr + size);
        local_y1_addr =
            ALIGN_UP_TCDM(local_x1_addr + size) + 8 * BANK_ALIGNMENT;
        local_z1_addr =
            ALIGN_UP_TCDM(local_y1_addr + size) + 16 * BANK_ALIGNMENT;
        local_x[1] = (double *)local_x1_addr;
        local_y[1] = (double *)local_y1_addr;
        local_z[1] = (double *)local_z1_addr;
    }

    iterations = args->n_tiles;
    if (double_buffer) iterations += 2;

    for (i = 0; i < iterations; i++) {
        if (snrt_is_dm_core()) {
            if (!double_buffer || (i < args->n_tiles)) {
                snrt_mcycle();
                i_dma_in = i;
                buff_idx = double_buffer ? i_dma_in % 2 : 0;
                offset = i_dma_in * frac;
                remote_x = args->x + offset;
                remote_y = args->y + offset;
                snrt_dma_start_1d(local_x[buff_idx], remote_x, size);
                snrt_dma_start_1d(local_y[buff_idx], remote_y, size);
                snrt_dma_wait_all();
                snrt_mcycle();
            }
            if (!double_buffer) snrt_cluster_hw_barrier();
            if (!double_buffer) snrt_cluster_hw_barrier();
            if (!double_buffer || (i > 1)) {
                snrt_mcycle();
                i_dma_out = double_buffer ? i - 2 : i;
                buff_idx = double_buffer ? i_dma_out % 2 : 0;
                offset = i_dma_out * frac;
                remote_z = args->z + offset;
                snrt_dma_start_1d(remote_z, local_z[buff_idx], size);
                snrt_dma_wait_all();
                snrt_mcycle();
            }
        }

        if (snrt_is_compute_core()) {
            if (!double_buffer) snrt_cluster_hw_barrier();
            if (!double_buffer || (i > 0 && i < (args->n_tiles + 1))) {
                i_compute = double_buffer ? i - 1 : i;
                buff_idx = double_buffer ? i_compute % 2 : 0;
                axpy_fp_t fp = args->funcptr;
                fp(frac, args->a, local_x[buff_idx], local_y[buff_idx],
                   local_z[buff_idx]);
            }
            if (!double_buffer) snrt_cluster_hw_barrier();
        }

        snrt_cluster_hw_barrier();
    }
    snrt_mcycle();
}
