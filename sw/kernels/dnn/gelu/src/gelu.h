// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "math.h"
#include "snrt.h"

#include "gelu_fp32.h"

typedef void (*gelu_fp_t)(float *in, float *out, uint32_t size);

typedef struct {
    uint32_t size;
    uint32_t n_tiles;
    void *ifmap;
    void *ofmap;
    precision_t dtype;
    gelu_fp_t funcptr;
} gelu_layer_t;

// Tiles the flat size axis across clusters.
// Requires size % n_tiles == 0 and n_tiles % num_clusters == 0.
static inline void gelu_layer(gelu_layer_t l) {
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
