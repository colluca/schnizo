// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "math.h"
#include "snrt.h"

#ifndef FREP
#ifdef FORCE_HW_LOOP
#define FREP "frep.i"
#else
#define FREP "frep.o"
#endif
#endif

typedef void (*rms_norm_fp_t)(float *ifmap, float *weight, float *ofmap,
                               uint32_t batch_size, uint32_t seq_len,
                               uint32_t hidden_dim, float eps);

typedef struct {
    uint32_t batch_size;
    uint32_t seq_len;
    uint32_t hidden_dim;
    uint32_t n_tiles;
    float eps;
    void *ifmap;
    void *ofmap;
    void *weight;
    precision_t dtype;
    rms_norm_fp_t funcptr;
} rms_norm_layer_t;

static inline void rms_norm_fp32_naive(float *ifmap, float *weight, float *ofmap,
                                   uint32_t batch_size, uint32_t seq_len,
                                   uint32_t hidden_dim, float eps) {
    uint32_t num_cores = snrt_cluster_compute_core_num();
    uint32_t core_idx  = snrt_cluster_core_idx();
    for (uint32_t b = 0; b < batch_size; b++) {
        for (uint32_t s = core_idx; s < seq_len; s += num_cores) {
            float *x = ifmap + (b * seq_len + s) * hidden_dim;
            float *y = ofmap + (b * seq_len + s) * hidden_dim;
            float sum_sq = 0.0f;
            for (uint32_t d = 0; d < hidden_dim; d++)
                sum_sq += x[d] * x[d];
            float inv_rms = 1.0f / sqrtf(sum_sq / hidden_dim + eps);
            for (uint32_t d = 0; d < hidden_dim; d++)
                y[d] = x[d] * inv_rms * weight[d];
        }
    }
}

// 4-accumulator pass 1 to break loop-carried dep; unrolled pass 2.
static inline void rms_norm_fp32_baseline(float *ifmap, float *weight, float *ofmap,
                                      uint32_t batch_size, uint32_t seq_len,
                                      uint32_t hidden_dim, float eps) {
    uint32_t num_cores = snrt_cluster_compute_core_num();
    uint32_t core_idx  = snrt_cluster_core_idx();
    for (uint32_t b = 0; b < batch_size; b++) {
        for (uint32_t s = core_idx; s < seq_len; s += num_cores) {
            float *x = ifmap + (b * seq_len + s) * hidden_dim;
            float *y = ofmap + (b * seq_len + s) * hidden_dim;
            float sq0 = 0.0f, sq1 = 0.0f, sq2 = 0.0f, sq3 = 0.0f;
            for (uint32_t d = 0; d < hidden_dim; d += 4) {
                sq0 += x[d+0] * x[d+0];
                sq1 += x[d+1] * x[d+1];
                sq2 += x[d+2] * x[d+2];
                sq3 += x[d+3] * x[d+3];
            }
            float inv_rms = 1.0f / sqrtf((sq0+sq1+sq2+sq3) / hidden_dim + eps);
            #pragma clang loop unroll_count(4)
            for (uint32_t d = 0; d < hidden_dim; d++)
                y[d] = x[d] * inv_rms * weight[d];
        }
    }
}

// Pass 1: 4-stream fmadd.s reduction (9 insns). Pass 2: dual fmul.s 8-unrolled (43 insns).
// Assumes hidden_dim % 8 == 0.
static inline void rms_norm_fp32_schnizo(float *ifmap, float *weight, float *ofmap,
                                     uint32_t batch_size, uint32_t seq_len,
                                     uint32_t hidden_dim, float eps) {
    uint32_t num_cores = snrt_cluster_compute_core_num();
    uint32_t core_idx  = snrt_cluster_core_idx();
    int n_frep  = (int)(hidden_dim / 4) - 1;
    int n_frep2 = (int)(hidden_dim / 8) - 1;
    for (uint32_t b = 0; b < batch_size; b++) {
        for (uint32_t s = core_idx; s < seq_len; s += num_cores) {
            float *x = ifmap + (b * seq_len + s) * hidden_dim;
            float *y = ofmap + (b * seq_len + s) * hidden_dim;
            float s0 = 0.0f, s1 = 0.0f, s2 = 0.0f, s3 = 0.0f;
            float *xp = x;
            asm volatile(
                FREP       " %[n], 9, 0, 0              \n"
                "flw        fa0,  0(%[xp])              \n"
                "flw        fa1,  4(%[xp])              \n"
                "flw        fa2,  8(%[xp])              \n"
                "flw        fa3, 12(%[xp])              \n"
                "fmadd.s    %[s0], fa0, fa0, %[s0]      \n"
                "fmadd.s    %[s1], fa1, fa1, %[s1]      \n"
                "fmadd.s    %[s2], fa2, fa2, %[s2]      \n"
                "fmadd.s    %[s3], fa3, fa3, %[s3]      \n"
                "addi       %[xp], %[xp], 16           \n"
                : [s0] "+f"(s0), [s1] "+f"(s1), [s2] "+f"(s2), [s3] "+f"(s3),
                  [xp] "+r"(xp)
                : [n]  "r"(n_frep)
                : "fa0", "fa1", "fa2", "fa3"
            );
            float inv_rms = 1.0f / sqrtf((s0+s1+s2+s3) / hidden_dim + eps);
            float *x2 = x, *wp = weight, *yp = y;
            asm volatile(
                // Peel iteration i=0
                "flw        fa0,  0(%[x2])               \n"
                "flw        ft0,  0(%[wp])               \n"
                "flw        fa1,  4(%[x2])               \n"
                "flw        ft1,  4(%[wp])               \n"
                "flw        fa2,  8(%[x2])               \n"
                "flw        ft2,  8(%[wp])               \n"
                "flw        fa3, 12(%[x2])               \n"
                "flw        ft3, 12(%[wp])               \n"
                "flw        fa4, 16(%[x2])               \n"
                "flw        ft4, 16(%[wp])               \n"
                "flw        fa5, 20(%[x2])               \n"
                "flw        ft5, 20(%[wp])               \n"
                "flw        fa6, 24(%[x2])               \n"
                "flw        ft6, 24(%[wp])               \n"
                "flw        fa7, 28(%[x2])               \n"
                "flw        ft7, 28(%[wp])               \n"
                "fmul.s     fa0, fa0, %[irms]            \n"
                "fmul.s     fa1, fa1, %[irms]            \n"
                "fmul.s     fa2, fa2, %[irms]            \n"
                "fmul.s     fa3, fa3, %[irms]            \n"
                "fmul.s     fa0, fa0, ft0                \n"
                "fmul.s     fa1, fa1, ft1                \n"
                "fmul.s     fa2, fa2, ft2                \n"
                "fmul.s     fa3, fa3, ft3                \n"
                "fmul.s     fa4, fa4, %[irms]            \n"
                "fmul.s     fa5, fa5, %[irms]            \n"
                "fmul.s     fa6, fa6, %[irms]            \n"
                "fmul.s     fa7, fa7, %[irms]            \n"
                "fmul.s     fa4, fa4, ft4                \n"
                "fmul.s     fa5, fa5, ft5                \n"
                "fmul.s     fa6, fa6, ft6                \n"
                "fmul.s     fa7, fa7, ft7                \n"
                FREP       " %[n], 43, 0, 0              \n"
                // Finish iteration i
                "addi       %[x2], %[x2], 32             \n"
                "addi       %[wp], %[wp], 32             \n"
                "fsw        fa0,  0(%[yp])               \n"
                "fsw        fa1,  4(%[yp])               \n"
                "fsw        fa2,  8(%[yp])               \n"
                "fsw        fa3, 12(%[yp])               \n"
                // Start iteration i+1
                "flw        fa0,  0(%[x2])               \n"
                "flw        ft0,  0(%[wp])               \n"
                "flw        fa1,  4(%[x2])               \n"
                "flw        ft1,  4(%[wp])               \n"
                "flw        fa2,  8(%[x2])               \n"
                "flw        ft2,  8(%[wp])               \n"
                "flw        fa3, 12(%[x2])               \n"
                "flw        ft3, 12(%[wp])               \n"
                "fmul.s     fa0, fa0, %[irms]            \n"
                "fmul.s     fa1, fa1, %[irms]            \n"
                "fmul.s     fa2, fa2, %[irms]            \n"
                "fmul.s     fa3, fa3, %[irms]            \n"
                "fmul.s     fa0, fa0, ft0                \n"
                "fmul.s     fa1, fa1, ft1                \n"
                "fmul.s     fa2, fa2, ft2                \n"
                "fmul.s     fa3, fa3, ft3                \n"
                // Finish iteration i
                "fsw        fa4, 16(%[yp])               \n"
                "fsw        fa5, 20(%[yp])               \n"
                "fsw        fa6, 24(%[yp])               \n"
                "fsw        fa7, 28(%[yp])               \n"
                "addi       %[yp], %[yp], 32             \n"
                // Finish iteration i+1
                "flw        fa4, 16(%[x2])               \n"
                "flw        ft4, 16(%[wp])               \n"
                "flw        fa5, 20(%[x2])               \n"
                "flw        ft5, 20(%[wp])               \n"
                "flw        fa6, 24(%[x2])               \n"
                "flw        ft6, 24(%[wp])               \n"
                "flw        fa7, 28(%[x2])               \n"
                "flw        ft7, 28(%[wp])               \n"
                "fmul.s     fa4, fa4, %[irms]            \n"
                "fmul.s     fa5, fa5, %[irms]            \n"
                "fmul.s     fa6, fa6, %[irms]            \n"
                "fmul.s     fa7, fa7, %[irms]            \n"
                "fmul.s     fa4, fa4, ft4                \n"
                "fmul.s     fa5, fa5, ft5                \n"
                "fmul.s     fa6, fa6, ft6                \n"
                "fmul.s     fa7, fa7, ft7                \n"
                // Finish last iteration (outside loop)
                "fsw        fa0,  0(%[yp])               \n"
                "fsw        fa1,  4(%[yp])               \n"
                "fsw        fa2,  8(%[yp])               \n"
                "fsw        fa3, 12(%[yp])               \n"
                "fsw        fa4, 16(%[yp])               \n"
                "fsw        fa5, 20(%[yp])               \n"
                "fsw        fa6, 24(%[yp])               \n"
                "fsw        fa7, 28(%[yp])               \n"
                : [x2] "+r"(x2), [wp] "+r"(wp), [yp] "+r"(yp)
                : [n]   "r"(n_frep2 - 1), [irms] "f"(inv_rms)
                : "fa0","fa1","fa2","fa3","fa4","fa5","fa6","fa7",
                  "ft0","ft1","ft2","ft3","ft4","ft5","ft6","ft7","memory"
            );
        }
    }
}

// Tiles seq_len across clusters (assumes seq_len is an integer multiple of n_tiles,
// and n_tiles is an integer multiple of the number of clusters).
static inline void rms_norm_layer(rms_norm_layer_t l) {
    uint32_t data_type_size = l.dtype;

    uint32_t n_tiles_per_cluster = l.n_tiles / snrt_cluster_num();
    uint32_t tile_seq_len = l.seq_len / l.n_tiles;
    uint32_t tile_size = l.batch_size * tile_seq_len * l.hidden_dim * data_type_size;
    uint32_t tile_offset = tile_seq_len * l.hidden_dim * data_type_size;
    uint32_t weight_size = l.hidden_dim * data_type_size;

    char *local_itile  = (char *)snrt_l1_next();
    char *local_otile  = local_itile + tile_size;
    char *local_weight = local_otile  + tile_size;

    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(local_weight, l.weight, weight_size);
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();

    char *remote_ifmap = (char *)l.ifmap;
    char *remote_ofmap = (char *)l.ofmap;

    for (uint32_t cluster_tile_idx = 0; cluster_tile_idx < n_tiles_per_cluster;
         cluster_tile_idx++) {
        uint32_t tile_idx =
            snrt_cluster_idx() * n_tiles_per_cluster + cluster_tile_idx;

        if (snrt_is_dm_core()) {
            snrt_dma_start_2d(
                local_itile,
                remote_ifmap + tile_idx * tile_offset,
                tile_seq_len * l.hidden_dim * data_type_size,
                tile_seq_len * l.hidden_dim * data_type_size,
                l.seq_len * l.hidden_dim * data_type_size,
                l.batch_size
            );
            snrt_dma_wait_all();
        }

        snrt_cluster_hw_barrier();

        if (snrt_is_compute_core()) {
            snrt_mcycle();
            l.funcptr((float *)local_itile, (float *)local_weight,
                      (float *)local_otile, l.batch_size,
                      tile_seq_len, l.hidden_dim, l.eps);
            snrt_mcycle();
        }

        snrt_cluster_hw_barrier();

        if (snrt_is_dm_core()) {
            snrt_dma_start_2d(
                remote_ofmap + tile_idx * tile_offset,
                local_otile,
                tile_seq_len * l.hidden_dim * data_type_size,
                l.seq_len * l.hidden_dim * data_type_size,
                tile_seq_len * l.hidden_dim * data_type_size,
                l.batch_size
            );
            snrt_dma_wait_all();
        }
    }

    snrt_global_barrier();
}
