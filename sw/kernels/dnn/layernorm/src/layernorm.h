// Copyright 2020 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "dnn.h"
#include "math.h"
#include "snrt.h"

#include "layernorm_fp16.h"
#include "layernorm_fp32.h"
#include "layernorm_fp8.h"

typedef void (*layernorm_fp_t)(void *ifmap, void *ofmap, uint32_t batch_size,
                               uint32_t seq_len, uint32_t embeddings,
                               float eps);

typedef struct layernorm_layer_struct {
    uint32_t batch_size;
    uint32_t seq_len;
    uint32_t embeddings;
    uint32_t n_tiles;
    layernorm_fp_t funcptr;
    float eps;
    void *ifmap;
    void *ofmap;
    precision_t dtype;
} layernorm_layer_t;

// Tiles the seq_len axis (assumes seq_len is an integer multiple of n_tiles)
// Distributes tiles to clusters (assumes n_tiles is an integer multiple of
// the number of clusters)
static inline void layernorm_layer(layernorm_layer_t l) {
    uint32_t data_type_size = l.dtype;

    uint32_t n_tiles_per_cluster = l.n_tiles / snrt_cluster_num();
    uint32_t tile_seq_len = l.seq_len / l.n_tiles;
    uint32_t tile_size =
        l.batch_size * tile_seq_len * l.embeddings * data_type_size;
    uint32_t tile_offset = tile_seq_len * l.embeddings * data_type_size;

    char *local_itile = (char *)snrt_l1_next();
    char *local_otile = local_itile + tile_size;
    char *remote_ifmap = (char *)l.ifmap;
    char *remote_ofmap = (char *)l.ofmap;

    for (uint32_t cluster_tile_idx = 0; cluster_tile_idx < n_tiles_per_cluster;
         cluster_tile_idx++) {
        uint32_t tile_idx =
            snrt_cluster_idx() * n_tiles_per_cluster + cluster_tile_idx;

        if (snrt_is_dm_core()) {
            void *remote_itile = remote_ifmap + tile_idx * tile_offset;
            snrt_dma_start_2d(local_itile, remote_itile,
                              tile_seq_len * l.embeddings * data_type_size,
                              tile_seq_len * l.embeddings * data_type_size,
                              l.seq_len * l.embeddings * data_type_size,
                              l.batch_size);
            snrt_dma_wait_all();
        }

        snrt_cluster_hw_barrier();

        if (snrt_is_compute_core()) {
            snrt_mcycle();
            l.funcptr(local_itile, local_otile, l.batch_size, tile_seq_len,
                      l.embeddings, l.eps);
            snrt_mcycle();
        }

        snrt_cluster_hw_barrier();

        if (snrt_is_dm_core()) {
            void *remote_otile = remote_ofmap + tile_idx * tile_offset;
            snrt_dma_start_2d(remote_otile, local_otile,
                              tile_seq_len * l.embeddings * data_type_size,
                              l.seq_len * l.embeddings * data_type_size,
                              tile_seq_len * l.embeddings * data_type_size,
                              l.batch_size);
            snrt_dma_wait_all();
        }
    }

    snrt_global_barrier();
}
