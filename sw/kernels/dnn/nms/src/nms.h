// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "snrt.h"

typedef struct {
    uint32_t num_boxes;
    float iou_threshold;
    void *boxes;     // [num_boxes, 4] float (x1,y1,x2,y2)
    void *scores;    // [num_boxes] float
    uint32_t *keep;  // [num_boxes] output: 1=kept, 0=suppressed
    precision_t dtype;
} nms_layer_t;

// Insertion sort on indices by descending score.
static inline void sort_desc(uint32_t *idx, float *scores, uint32_t n) {
    for (uint32_t i = 1; i < n; i++) {
        uint32_t key = idx[i];
        float key_score = scores[key];
        int32_t j = (int32_t)i - 1;
        while (j >= 0 && scores[idx[j]] < key_score) {
            idx[j + 1] = idx[j];
            j--;
        }
        idx[j + 1] = key;
    }
}

static inline float iou(float *boxes, uint32_t i, uint32_t j) {
    float *bi = boxes + i * 4;
    float *bj = boxes + j * 4;

    float ix1 = bi[0] > bj[0] ? bi[0] : bj[0];
    float iy1 = bi[1] > bj[1] ? bi[1] : bj[1];
    float ix2 = bi[2] < bj[2] ? bi[2] : bj[2];
    float iy2 = bi[3] < bj[3] ? bi[3] : bj[3];

    float inter_w = ix2 - ix1;
    float inter_h = iy2 - iy1;
    if (inter_w <= 0.0f || inter_h <= 0.0f) return 0.0f;
    float inter = inter_w * inter_h;

    float area_i = (bi[2] - bi[0]) * (bi[3] - bi[1]);
    float area_j = (bj[2] - bj[0]) * (bj[3] - bj[1]);
    return inter / (area_i + area_j - inter);
}

// Naive O(n²) NMS. Runs single-core on core 0; all other cores wait.
// All data (boxes, scores, keep, sort buffer) must fit in TCDM.
static inline void nms_layer(nms_layer_t l) {
    uint32_t n = l.num_boxes;
    uint32_t boxes_bytes = n * 4 * sizeof(float);
    uint32_t scores_bytes = n * sizeof(float);
    uint32_t keep_bytes = n * sizeof(uint32_t);
    uint32_t idx_bytes = n * sizeof(uint32_t);

    snrt_mcycle();

    char *local_boxes = (char *)snrt_l1_next();
    char *local_scores = local_boxes + boxes_bytes;
    uint32_t *local_keep = (uint32_t *)(local_scores + scores_bytes);
    uint32_t *local_idx = local_keep + n;

    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(local_boxes, l.boxes, boxes_bytes);
        snrt_dma_start_1d(local_scores, l.scores, scores_bytes);
        snrt_dma_wait_all();
        snrt_mcycle();
    }

    snrt_cluster_hw_barrier();

    // Only core 0 runs the sequential greedy NMS
    if (snrt_is_compute_core() && snrt_cluster_core_idx() == 0) {
        snrt_mcycle();

        float *boxes = (float *)local_boxes;
        float *scores = (float *)local_scores;

        // Initialize sorted index array
        for (uint32_t i = 0; i < n; i++) local_idx[i] = i;
        sort_desc(local_idx, scores, n);

        // Greedy suppression
        for (uint32_t i = 0; i < n; i++) local_keep[i] = 1;

        for (uint32_t i = 0; i < n; i++) {
            uint32_t bi = local_idx[i];
            if (!local_keep[bi]) continue;
            for (uint32_t j = i + 1; j < n; j++) {
                uint32_t bj = local_idx[j];
                if (!local_keep[bj]) continue;
                if (iou(boxes, bi, bj) > l.iou_threshold) local_keep[bj] = 0;
            }
        }

        snrt_mcycle();
    }

    snrt_cluster_hw_barrier();

    if (snrt_is_dm_core()) {
        snrt_mcycle();
        snrt_dma_start_1d(l.keep, local_keep, keep_bytes);
        snrt_dma_wait_all();
        snrt_mcycle();
    }

    snrt_global_barrier();
}
