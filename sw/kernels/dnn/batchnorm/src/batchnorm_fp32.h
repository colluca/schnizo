// Copyright 2020 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "snrt.h"

#ifdef FORCE_HW_LOOP
#define FREP "frep.i"
#else
#define FREP "frep.o"
#endif

// Load-use-store kernel: frep.i -> 4x unroll, frep.o -> scalar.
// Data layout: CHW — ifmap[CI, n_pixels], contiguous per channel.
// Cores take interleaved channels.

static inline void batchnorm_fp32_naive(void *ifmap, void *gamma, void *beta,
                                         void *ofmap, uint32_t CI,
                                         uint32_t n_pixels) {
    float *in  = (float *)ifmap;
    float *g   = (float *)gamma;
    float *b   = (float *)beta;
    float *out = (float *)ofmap;
    uint32_t num_cores = snrt_cluster_compute_core_num();
    uint32_t core_idx  = snrt_cluster_core_idx();
    for (uint32_t c = core_idx; c < CI; c += num_cores) {
        float gc = g[c];
        float bc = b[c];
        for (uint32_t p = 0; p < n_pixels; p++)
            out[c * n_pixels + p] = in[c * n_pixels + p] * gc + bc;
    }
}

static inline void batchnorm_fp32_baseline(void *ifmap, void *gamma, void *beta,
                                            void *ofmap, uint32_t CI,
                                            uint32_t n_pixels) {
    float *in  = (float *)ifmap;
    float *g   = (float *)gamma;
    float *b   = (float *)beta;
    float *out = (float *)ofmap;
    uint32_t num_cores = snrt_cluster_compute_core_num();
    uint32_t core_idx  = snrt_cluster_core_idx();
    for (uint32_t c = core_idx; c < CI; c += num_cores) {
        float gc = g[c];
        float bc = b[c];
        #pragma clang loop unroll_count(4)
        for (uint32_t p = 0; p < n_pixels; p++)
            out[c * n_pixels + p] = in[c * n_pixels + p] * gc + bc;
    }
}

static inline void batchnorm_fp32_schnizo(void *ifmap, void *gamma, void *beta,
                                           void *ofmap, uint32_t CI,
                                           uint32_t n_pixels) {
    float *in  = (float *)ifmap;
    float *g   = (float *)gamma;
    float *b   = (float *)beta;
    float *out = (float *)ofmap;
    uint32_t num_cores = snrt_cluster_compute_core_num();
    uint32_t core_idx  = snrt_cluster_core_idx();
    for (uint32_t c = core_idx; c < CI; c += num_cores) {
        float gc = g[c];
        float bc = b[c];
        float *cin  = in  + c * n_pixels;
        float *cout = out + c * n_pixels;
#ifdef FORCE_HW_LOOP
        int n_frep = n_pixels / 4 - 1;
        asm volatile(
            "frep.i  %[n], 14, 0, 0          \n"
            "flw     fa0,  0(%[in])           \n"
            "flw     fa1,  4(%[in])           \n"
            "flw     fa2,  8(%[in])           \n"
            "flw     fa3, 12(%[in])           \n"
            "fmadd.s fa0, fa0, %[g], %[b]    \n"
            "fmadd.s fa1, fa1, %[g], %[b]    \n"
            "fmadd.s fa2, fa2, %[g], %[b]    \n"
            "fmadd.s fa3, fa3, %[g], %[b]    \n"
            "fsw     fa0,  0(%[out])          \n"
            "fsw     fa1,  4(%[out])          \n"
            "fsw     fa2,  8(%[out])          \n"
            "fsw     fa3, 12(%[out])          \n"
            "addi    %[in],  %[in],  16       \n"
            "addi    %[out], %[out], 16       \n"
            : [in] "+r"(cin), [out] "+r"(cout)
            : [n] "r"(n_frep), [g] "f"(gc), [b] "f"(bc)
            : "fa0", "fa1", "fa2", "fa3", "memory"
        );
#else
        int n_frep = n_pixels - 1;
        asm volatile(
            "frep.o  %[n], 5, 0, 0           \n"
            "flw     fa0,  0(%[in])           \n"
            "fmadd.s fa0, fa0, %[g], %[b]    \n"
            "fsw     fa0,  0(%[out])          \n"
            "addi    %[in],  %[in],  4        \n"
            "addi    %[out], %[out], 4        \n"
            : [in] "+r"(cin), [out] "+r"(cout)
            : [n] "r"(n_frep), [g] "f"(gc), [b] "f"(bc)
            : "fa0", "memory"
        );
#endif
    }
}
