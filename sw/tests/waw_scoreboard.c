// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Check that WAW hazards are managed properly by the scoreboard.
// This especially applies to the Schnizo WAW optimization.

#include "snrt.h"

int main() {
    if (snrt_is_compute_core()) {
        int errs = 3;
        int result;
        int input;
        
        // Single cycle instructions
        input = 11;
        asm volatile(
            "addi %[out], %[in], 42\n"
            "addi %[out], %[in], 22\n"
            : [out] "=r"(result)
            : [in] "r"(input)
            :
        );

        errs -= (result == (input + 22));

        // WAW for load on integer register file
        int someValue = 32;
        input = 11;
        asm volatile(
            "lw %[out], 0(%[addr])\n"
            "addi %[out], %[in], 42\n" // this addi should block
            : [out] "+r"(result)
            : [in] "r"(input), [addr] "r"(&someValue)
            :
        );

        errs -= (result == (input + 42));

        // WAW on floating point register file
        uint32_t i8a = 0x4048F5C3;   // 3.14
        uint32_t i8an = 0xC048F5C3;  // -3.14
        uint32_t i8b = 0x3FCF1AA0;   // 1.618
        uint32_t i8bn = 0xBFCF1AA0;  // -1.618

        int compare_result;

        asm volatile(
            "fmv.s.x ft3, %0\n"
            "fmv.s.x ft4, %1\n"
            : "+r"(i8a), "+r"(i8b)
        );

        asm volatile(
            "fadd.s ft2, ft3, ft3\n"
            "fadd.s ft2, ft3, ft4\n"
            "fmv.x.w %0, ft2\n"
            : "=r"(compare_result)
        );

        errs -= (compare_result == 0x4098418a); // = 4.7580004

        return errs;
    }
    return 0;
}
