// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli  <petterli@student.ethz.ch>
// Stefan Odermatt <soderma@student.ethz.ch>

#include "snrt.h"

// Test if we can read and set the FREP config CSR.
int main() {
    if (!snrt_is_compute_core()) {
        return 0;
    }

    frep_mem_consistency_e mode;
    uint32_t load_mask, store_mask;

    // ---------------------------------------------------------
    // 1. Test Memory Consistency Mode
    // ---------------------------------------------------------
    mode = szrt_frep_mem_consistency();
    if (mode != FREP_MEM_NO_CONSISTENCY) {
        return 1;
    }

    szrt_set_frep_mem_consistency(FREP_MEM_SERIALIZED);
    if (szrt_frep_mem_consistency() != FREP_MEM_SERIALIZED) {
        return 2;
    }

    szrt_set_frep_mem_consistency(FREP_MEM_NO_CONSISTENCY);
    if (szrt_frep_mem_consistency() != FREP_MEM_NO_CONSISTENCY) {
        return 3;
    }

    // ---------------------------------------------------------
    // 2. Test Initial Hardware Defaults for LSU Capabilities
    // ---------------------------------------------------------
    // The hardware reset value is 7'b1111111 (0x7F)
    load_mask = szrt_frep_lsu_load_en();
    if (load_mask != 0x7F) {
        return 4;
    }

    store_mask = szrt_frep_lsu_store_en();
    if (store_mask != 0x7F) {
        return 5;
    }

    // ---------------------------------------------------------
    // 3. Test Modifying Load Enable Mask
    // ---------------------------------------------------------
    // Set Load Enable to 0x15 (binary 0010101 -> LSU0, LSU2, LSU4)
    szrt_set_frep_lsu_load_en(0x15);
    if (szrt_frep_lsu_load_en() != 0x15) {
        return 6;
    }
    // ISOLATION CHECK: Ensure Store Enable was NOT corrupted by the load write
    if (szrt_frep_lsu_store_en() != 0x7F) {
        return 7;
    }

    // ---------------------------------------------------------
    // 4. Test Modifying Store Enable Mask
    // ---------------------------------------------------------
    // Set Store Enable to 0x2A (binary 0101010 -> LSU1, LSU3, LSU5)
    szrt_set_frep_lsu_store_en(0x2A);
    if (szrt_frep_lsu_store_en() != 0x2A) {
        return 8;
    }
    // ISOLATION CHECK: Ensure Load Enable was NOT corrupted by the store write
    if (szrt_frep_lsu_load_en() != 0x15) {
        return 9;
    }
    // ISOLATION CHECK: Ensure Memory Consistency mode was NOT corrupted
    if (szrt_frep_mem_consistency() != FREP_MEM_NO_CONSISTENCY) {
        return 10;
    }

    // All tests passed successfully
    return 0;
}
