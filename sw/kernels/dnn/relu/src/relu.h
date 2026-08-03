// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "snrt.h"

#ifndef FREP
#ifdef FORCE_HW_LOOP
#define FREP "frep.i"
#else
#define FREP "frep.o"
#endif
#endif

typedef void (*relu_fp_t)(float *in, float *out, uint32_t size);

typedef struct {
    uint32_t size;
    uint32_t n_tiles;
    void *ifmap;
    void *ofmap;
    precision_t dtype;
    relu_fp_t funcptr;
} relu_layer_t;

static inline void relu_fp32_naive(float *in, float *out, uint32_t size) {
    for (uint32_t i = 0; i < size; i++) out[i] = in[i] > 0.0f ? in[i] : 0.0f;
}

static inline void relu_fp32_baseline(float *in, float *out, uint32_t size) {
#pragma clang loop unroll_count(4)
    for (uint32_t i = 0; i < size; i++) out[i] = in[i] > 0.0f ? in[i] : 0.0f;
}

// Load-use-store kernel: frep.i → 4x unroll, frep.o → scalar.
// frep.i: 4 flw + 4 fmax.s + 4 fsw + 2 addi = 14 insns, n_frep = size/4 - 1.
// frep.o: flw + fmax.s + fsw + 2 addi = 5 insns, n_frep = size - 1.
// ft3 = 0.0f held outside FREP in both cases.
static inline void relu_fp32_schnizo(float *in, float *out, uint32_t size) {
#ifdef FORCE_HW_LOOP
    int n_frep = size / 4 - 1;
    asm volatile(
        "fmv.w.x  ft3, zero              \n"
        "frep.i   %[n], 14, 0, 0         \n"
        "flw      fa0,  0(%[in])         \n"
        "flw      fa1,  4(%[in])         \n"
        "flw      fa2,  8(%[in])         \n"
        "flw      fa3, 12(%[in])         \n"
        "fmax.s   fa0, fa0, ft3          \n"
        "fmax.s   fa1, fa1, ft3          \n"
        "fmax.s   fa2, fa2, ft3          \n"
        "fmax.s   fa3, fa3, ft3          \n"
        "fsw      fa0,  0(%[out])        \n"
        "fsw      fa1,  4(%[out])        \n"
        "fsw      fa2,  8(%[out])        \n"
        "fsw      fa3, 12(%[out])        \n"
        "addi     %[in],  %[in],  16    \n"
        "addi     %[out], %[out], 16    \n"
        : [in] "+r"(in), [out] "+r"(out)
        : [n] "r"(n_frep)
        : "ft3", "fa0", "fa1", "fa2", "fa3", "memory");
#else
    int n_frep = size - 1;
    asm volatile(
        "fmv.w.x  ft3, zero              \n"
        "frep.o   %[n], 5, 0, 0          \n"
        "flw      fa0,  0(%[in])         \n"
        "fmax.s   fa0, fa0, ft3          \n"
        "fsw      fa0,  0(%[out])        \n"
        "addi     %[in],  %[in],   4    \n"
        "addi     %[out], %[out],  4    \n"
        : [in] "+r"(in), [out] "+r"(out)
        : [n] "r"(n_frep)
        : "ft3", "fa0", "memory");
#endif
}

// Load-use-store kernel: frep.i → 4x unroll, frep.o → scalar.
// frep.i: 4 flw + 4 fmax.s + 4 fsw + 2 addi = 14 insns, n_frep = size/4 - 1.
// frep.o: flw + fmax.s + fsw + 2 addi = 5 insns, n_frep = size - 1.
// ft3 = 0.0f held outside FREP in both cases.
static inline void relu_fp32_schnova(float *in, float *out, uint32_t size) {
#ifdef UNROLL
    // LSU0 is dedicated for loads
    uint32_t load_mask = (1 << 0);
    // LSU1 is dedicated for stores
    uint32_t store_mask = (1 << 1);
    if (szrt_nof_lsus() == 2) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en(load_mask);
        szrt_set_frep_lsu_store_en(store_mask);
    }
    int n_frep = size / 4 - 1;
    asm volatile("fmv.w.x  ft3, zero              \n" FREP
                 " %[n], 14, 0, 0         \n"
                 "flw      fa0,  0(%[in])         \n"
                 "flw      fa1,  4(%[in])         \n"
                 "flw      fa2,  8(%[in])         \n"
                 "flw      fa3, 12(%[in])         \n"
                 "fmax.s   fa0, fa0, ft3          \n"
                 "fmax.s   fa1, fa1, ft3          \n"
                 "fmax.s   fa2, fa2, ft3          \n"
                 "fmax.s   fa3, fa3, ft3          \n"
                 "fsw      fa0,  0(%[out])        \n"
                 "fsw      fa1,  4(%[out])        \n"
                 "fsw      fa2,  8(%[out])        \n"
                 "fsw      fa3, 12(%[out])        \n"
                 "addi     %[in],  %[in],  16    \n"
                 "addi     %[out], %[out], 16    \n"
                 : [in] "+r"(in), [out] "+r"(out)
                 : [n] "r"(n_frep)
                 : "ft3", "fa0", "fa1", "fa2", "fa3", "memory");
#elif defined(BALANCE_INSTRUCTION_MIX) && defined(UNROLL)
    // LSU0 is dedicated for loads
    uint32_t load_mask = (1 << 0);
    // LSU1 is dedicated for stores
    uint32_t store_mask = (1 << 1);
    if (szrt_nof_lsus() == 2) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en(load_mask);
        szrt_set_frep_lsu_store_en(store_mask);
    }
    int n_frep = size / 4 - 1;
    asm volatile("fmv.w.x  ft3, zero              \n" FREP
                 " %[n], 14, 0, 0         \n"
                 "flw      fa0,  0(%[in])         \n"
                 "fmax.s   fa0, fa0, ft3          \n"
                 "fsw      fa0,  0(%[out])        \n"
                 "flw      fa1,  4(%[in])         \n"
                 "fmax.s   fa1, fa1, ft3          \n"
                 "fsw      fa1,  4(%[out])        \n"
                 "flw      fa2,  8(%[in])         \n"
                 "fmax.s   fa2, fa2, ft3          \n"
                 "fsw      fa2,  8(%[out])        \n"
                 "flw      fa3, 12(%[in])         \n"
                 "fmax.s   fa3, fa3, ft3          \n"
                 "fsw      fa3, 12(%[out])        \n"
                 "addi     %[in],  %[in],  16    \n"
                 "addi     %[out], %[out], 16    \n"
                 : [in] "+r"(in), [out] "+r"(out)
                 : [n] "r"(n_frep)
                 : "ft3", "fa0", "fa1", "fa2", "fa3", "memory");
#else
    // LSU0 and LSU1 are dedicated for loads
    uint32_t load_mask = (1 << 0) | (1 << 1);
    // LSU2 is dedicated for stores
    uint32_t store_mask = (1 << 2);
    if (szrt_nof_lsus() >= 3) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en(load_mask);
        szrt_set_frep_lsu_store_en(store_mask);
    }
    int n_frep = size - 1;
    asm volatile(
        "nop                             \n"
        "nop                             \n"
        "nop                             \n"
        "nop                             \n"
        "nop                             \n"
        "fmv.w.x  ft3, zero              \n"
        "frep.o   %[n], 5, 0, 0          \n"
        "flw      fa0,  0(%[in])         \n"
        "fmax.s   fa0, fa0, ft3          \n"
        "fsw      fa0,  0(%[out])        \n"
        "addi     %[in],  %[in],   4    \n"
        "addi     %[out], %[out],  4    \n"
        : [in] "+r"(in), [out] "+r"(out)
        : [n] "r"(n_frep)
        : "ft3", "fa0", "memory");
#endif
}

// Tiles the flat size axis across clusters.
// Requires size % n_tiles == 0 and n_tiles % num_clusters == 0.
static inline void relu_layer(relu_layer_t l) {
    uint32_t data_type_size = l.dtype;

    uint32_t n_tiles_per_cluster = l.n_tiles / snrt_cluster_num();
    uint32_t tile_size = l.size / l.n_tiles;
    uint32_t tile_bytes = tile_size * data_type_size;

    char *local_in = (char *)snrt_l1_next();
    char *local_out = local_in + tile_bytes;

    char *remote_in = (char *)l.ifmap;
    char *remote_out = (char *)l.ofmap;

    for (uint32_t ct = 0; ct < n_tiles_per_cluster; ct++) {
        uint32_t tile_idx = snrt_cluster_idx() * n_tiles_per_cluster + ct;
        uint32_t byte_offset = tile_idx * tile_bytes;

        if (snrt_is_dm_core()) {
            snrt_dma_start_1d(local_in, remote_in + byte_offset, tile_bytes);
            snrt_dma_wait_all();
        }

        snrt_cluster_hw_barrier();

        if (snrt_is_compute_core()) {
            uint32_t num_cores = snrt_cluster_compute_core_num();
            uint32_t core_idx = snrt_cluster_core_idx();
            uint32_t per_core = tile_size / num_cores;
            snrt_mcycle();
            l.funcptr((float *)local_in + core_idx * per_core,
                      (float *)local_out + core_idx * per_core, per_core);
            snrt_mcycle();
        }

        snrt_cluster_hw_barrier();

        if (snrt_is_dm_core()) {
            snrt_dma_start_1d(remote_out + byte_offset, local_out, tile_bytes);
            snrt_dma_wait_all();
        }
    }

    snrt_global_barrier();
}
