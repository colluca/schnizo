// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "../../eltwise/src/eltwise.h"
#include "../../misc/exp/src/vexpf_fp32_schnizo.h"
#include "../../misc/exp/src/vexpf_fp32_schnova.h"
#include "math.h"
#include "snrt.h"

typedef void (*silu_fp_t)(float *in, float *out, uint32_t size);

typedef struct {
    uint32_t size;
    uint32_t n_tiles;
    void *ifmap;
    void *ofmap;
    precision_t dtype;
    silu_fp_t funcptr;
} silu_layer_t;

// SiLU (Swish): y = x * sigmoid(x) = x / (1 + exp(-x))
static inline void silu_fp32_naive(float *in, float *out, uint32_t size) {
    for (uint32_t i = 0; i < size; i++) out[i] = in[i] / (1.0f + expf(-in[i]));
}

// Optimized SiLU using vectorized exp and eltwise kernels.
// Requires size % 4 == 0 and size >= 8.
static inline void silu_fp32_schnizo(float *in, float *out, uint32_t size) {
    // Step 1: out[i] = -in[i]
    eltwise_fp32_schnizo(in, in, out, size, ELTWISE_NEG);

    // Step 2: out[i] = exp(-in[i])
    vexpf_fp32_schnizo(out, out, size);

    // Step 3: out[i] = 1.0f + out[i]  (load-use-store: frep.i=4x, frep.o=scalar)
    // Two pointers (src/dst both starting at out) avoids WAR hazard on pointer
    // register in frep.o mode.
    {
        float *src = out, *dst = out;
        float one = 1.0f;
#ifdef FORCE_HW_LOOP
        int n_frep = size / 4 - 1;
        asm volatile(
            // clang-format off
            "frep.i %[n], 14, 0, 0             \n"
            "flw    fa0,  0(%[src])            \n"
            "flw    fa1,  4(%[src])            \n"
            "flw    fa2,  8(%[src])            \n"
            "flw    fa3, 12(%[src])            \n"
            "fadd.s fa0, fa0, %[one]           \n"
            "fadd.s fa1, fa1, %[one]           \n"
            "fadd.s fa2, fa2, %[one]           \n"
            "fadd.s fa3, fa3, %[one]           \n"
            "fsw    fa0,  0(%[dst])            \n"
            "fsw    fa1,  4(%[dst])            \n"
            "fsw    fa2,  8(%[dst])            \n"
            "fsw    fa3, 12(%[dst])            \n"
            "addi   %[src], %[src], 16         \n"
            "addi   %[dst], %[dst], 16         \n"
            // clang-format on
            : [ src ] "+r"(src), [ dst ] "+r"(dst)
            : [ n ] "r"(n_frep), [ one ] "f"(one)
            : "fa0", "fa1", "fa2", "fa3", "memory");
#else
        int n_frep = size - 1;
        asm volatile(
            // clang-format off
            "frep.o %[n], 5, 0, 0              \n"
            "flw    fa0,  0(%[src])            \n"
            "fadd.s fa0, fa0, %[one]           \n"
            "fsw    fa0,  0(%[dst])            \n"
            "addi   %[src], %[src], 4          \n"
            "addi   %[dst], %[dst], 4          \n"
            // clang-format on
            : [ src ] "+r"(src), [ dst ] "+r"(dst)
            : [ n ] "r"(n_frep), [ one ] "f"(one)
            : "fa0", "memory");
#endif
    }
    // Step 4: out[i] = in[i] / out[i] = x / (1 + exp(-x))
    eltwise_fp32_schnizo(in, out, out, size, ELTWISE_DIV);
}

// Optimized SiLU using vectorized exp and eltwise kernels.
// Requires size % 4 == 0 and size >= 8.
static inline void silu_fp32_schnova(float *in, float *out, uint32_t size) {
    if (szrt_nof_lsus() >= 3) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en((1 << 0) | (1 << 1));
        szrt_set_frep_lsu_store_en((1 << 2));
    } else if (szrt_nof_lsus() == 2) {
        // Fix some LSUs to only accept load or store instructions
        szrt_set_frep_lsu_load_en((1 << 0));
        szrt_set_frep_lsu_store_en((1 << 1));
    }
    // Step 1: out[i] = -in[i]
    // Add some nops to align fetch block for schnova
    asm volatile(
        // clang-format off
        "nop       \n"
        "nop       \n"
        "nop       \n"
        "nop       \n"
        "nop       \n"
        // clang-format on
        ::
            :);
    eltwise_neg_fp32_schnova(in, in, out, size);

    // Step 2: out[i] = exp(-in[i])
    vexpf_fp32_schnova(out, out, size);

    // Step 3: out[i] = 1.0f + out[i]  (load-use-store: frep.i=4x, frep.o=scalar)
    // Two pointers (src/dst both starting at out) avoids WAR hazard on pointer
    // register in frep.o mode.
    {
        float *src = out, *dst = out;
        float one = 1.0f;
#ifdef FORCE_HW_LOOP
        int n_frep = size / 4 - 1;
        asm volatile(
            // clang-format off
            FREP  " %[n], 14, 0, 0             \n"
            "flw    fa0,  0(%[src])            \n"
            "flw    fa1,  4(%[src])            \n"
            "flw    fa2,  8(%[src])            \n"
            "flw    fa3, 12(%[src])            \n"
            "fadd.s fa0, fa0, %[one]           \n"
            "fadd.s fa1, fa1, %[one]           \n"
            "fadd.s fa2, fa2, %[one]           \n"
            "fadd.s fa3, fa3, %[one]           \n"
            "fsw    fa0,  0(%[dst])            \n"
            "fsw    fa1,  4(%[dst])            \n"
            "fsw    fa2,  8(%[dst])            \n"
            "fsw    fa3, 12(%[dst])            \n"
            "addi   %[src], %[src], 16         \n"
            "addi   %[dst], %[dst], 16         \n"
            // clang-format on
            : [ src ] "+r"(src), [ dst ] "+r"(dst)
            : [ n ] "r"(n_frep), [ one ] "f"(one)
            : "fa0", "fa1", "fa2", "fa3", "memory");
#elif defined(BALANCE_INSTRUCTION_MIX) && defined(UNROLL)
        int n_frep = size / 4 - 1;
        asm volatile(
            // clang-format off
            FREP  " %[n], 14, 0, 0             \n"
            "flw    fa0,  0(%[src])            \n"
            "flw    fa1,  4(%[src])            \n"
            "flw    fa2,  8(%[src])            \n"
            "flw    fa3, 12(%[src])            \n"
            "fadd.s fa0, fa0, %[one]           \n"
            "fadd.s fa1, fa1, %[one]           \n"
            "fadd.s fa2, fa2, %[one]           \n"
            "fadd.s fa3, fa3, %[one]           \n"
            "fsw    fa0,  0(%[dst])            \n"
            "fsw    fa1,  4(%[dst])            \n"
            "fsw    fa2,  8(%[dst])            \n"
            "fsw    fa3, 12(%[dst])            \n"
            "addi   %[src], %[src], 16         \n"
            "addi   %[dst], %[dst], 16         \n"
            // clang-format on
            : [ src ] "+r"(src), [ dst ] "+r"(dst)
            : [ n ] "r"(n_frep), [ one ] "f"(one)
            : "fa0", "fa1", "fa2", "fa3", "memory");
#else
        int n_frep = size - 1;
        asm volatile(
            // clang-format off
            "nop       \n"
            "nop       \n"
            "nop       \n"
            "nop       \n"
            "frep.o %[n], 5, 0, 0              \n"
            "flw    fa0,  0(%[src])            \n"
            "fadd.s fa0, fa0, %[one]           \n"
            "fsw    fa0,  0(%[dst])            \n"
            "addi   %[src], %[src], 4          \n"
            "addi   %[dst], %[dst], 4          \n"
            // clang-format on
            : [ src ] "+r"(src), [ dst ] "+r"(dst)
            : [ n ] "r"(n_frep), [ one ] "f"(one)
            : "fa0", "memory");
#endif
    }
    // Add some nops to align fetch block for schnova
    asm volatile(
        // clang-format off
        "nop       \n"
        "nop       \n"
        "nop       \n"
        "nop       \n"
        // clang-format on
        ::
            :);
    // Step 4: out[i] = in[i] / out[i] = x / (1 + exp(-x))
    eltwise_div_fp32_schnova(in, out, out, size);
}

// Tiles the flat size axis across clusters.
// Requires size % n_tiles == 0 and n_tiles % num_clusters == 0.
static inline void silu_layer(silu_layer_t l) {
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
