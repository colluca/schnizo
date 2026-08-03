// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "math.h"
#include "snrt.h"

typedef struct {
    uint32_t batch_size;
    uint32_t channels;
    uint32_t in_height;
    uint32_t in_width;
    uint32_t out_height;
    uint32_t out_width;
    void *ifmap;
    void *ofmap;
    precision_t dtype;
} interpolate_layer_t;

// Bilinear 2D upsampling, align_corners=False (PyTorch default).
// Each compute core handles a subset of (batch, channel) planes.
static inline void interpolate_bilinear_fp32(float *in, float *out,
                                             uint32_t batch_size,
                                             uint32_t channels, uint32_t in_h,
                                             uint32_t in_w, uint32_t out_h,
                                             uint32_t out_w) {
    uint32_t num_cores = snrt_cluster_compute_core_num();
    uint32_t core_idx = snrt_cluster_core_idx();
    uint32_t num_planes = batch_size * channels;

    for (uint32_t p = core_idx; p < num_planes; p += num_cores) {
        float *src = in + p * in_h * in_w;
        float *dst = out + p * out_h * out_w;

        for (uint32_t oh = 0; oh < out_h; oh++) {
            // Continuous source coordinate (align_corners=False)
            float ih_f = ((float)oh + 0.5f) * (float)in_h / (float)out_h - 0.5f;
            int ih0 = (int)floorf(ih_f);
            int ih1 = ih0 + 1;
            float dy = ih_f - (float)ih0;
            // Clamp to valid range
            if (ih0 < 0) ih0 = 0;
            if (ih1 >= (int)in_h) ih1 = (int)in_h - 1;

            for (uint32_t ow = 0; ow < out_w; ow++) {
                float iw_f =
                    ((float)ow + 0.5f) * (float)in_w / (float)out_w - 0.5f;
                int iw0 = (int)floorf(iw_f);
                int iw1 = iw0 + 1;
                float dx = iw_f - (float)iw0;
                if (iw0 < 0) iw0 = 0;
                if (iw1 >= (int)in_w) iw1 = (int)in_w - 1;

                float v00 = src[ih0 * in_w + iw0];
                float v01 = src[ih0 * in_w + iw1];
                float v10 = src[ih1 * in_w + iw0];
                float v11 = src[ih1 * in_w + iw1];

                dst[oh * out_w + ow] =
                    (1.0f - dy) * ((1.0f - dx) * v00 + dx * v01) +
                    dy * ((1.0f - dx) * v10 + dx * v11);
            }
        }
    }
}

// Distributes (batch × channels) planes across clusters.
// Each cluster processes its slice of planes entirely in TCDM.
// Requires (batch_size * channels) % num_clusters == 0.
static inline void interpolate_layer(interpolate_layer_t l) {
    uint32_t data_type_size = l.dtype;

    snrt_mcycle();

    uint32_t num_planes = l.batch_size * l.channels;
    uint32_t planes_per_cluster = num_planes / snrt_cluster_num();
    uint32_t in_plane_bytes = l.in_height * l.in_width * data_type_size;
    uint32_t out_plane_bytes = l.out_height * l.out_width * data_type_size;

    char *local_in = (char *)snrt_l1_next();
    char *local_out = local_in + planes_per_cluster * in_plane_bytes;

    uint32_t cluster_plane_offset = snrt_cluster_idx() * planes_per_cluster;
    char *remote_in = (char *)l.ifmap + cluster_plane_offset * in_plane_bytes;
    char *remote_out = (char *)l.ofmap + cluster_plane_offset * out_plane_bytes;

    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(local_in, remote_in,
                          planes_per_cluster * in_plane_bytes);
        snrt_dma_wait_all();
        snrt_mcycle();
    }

    snrt_cluster_hw_barrier();

    if (snrt_is_compute_core()) {
        snrt_mcycle();
        switch (l.dtype) {
            case FP32:
                interpolate_bilinear_fp32((float *)local_in, (float *)local_out,
                                          l.batch_size, planes_per_cluster,
                                          l.in_height, l.in_width, l.out_height,
                                          l.out_width);
                break;
            default:
                break;
        }
        snrt_mcycle();
    }

    snrt_cluster_hw_barrier();

    if (snrt_is_dm_core()) {
        snrt_mcycle();
        snrt_dma_start_1d(remote_out, local_out,
                          planes_per_cluster * out_plane_bytes);
        snrt_dma_wait_all();
        snrt_mcycle();
    }

    snrt_global_barrier();
}
