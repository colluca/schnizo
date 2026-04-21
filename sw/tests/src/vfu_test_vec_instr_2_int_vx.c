// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "snrt.h"
#include <stdint.h>

// 6 NOPs after every vector instruction to drain pipeline hazards
#define NOPS() asm volatile( \
    "addi x0, x0, 0\n" \
    "addi x0, x0, 0\n" \
    "addi x0, x0, 0\n" \
    "addi x0, x0, 0\n" \
    "addi x0, x0, 0\n" \
    "addi x0, x0, 0\n" \
)

#define SECTION_END(name) \
    if (errors == sec_errors) printf("[PASS] " name "\n"); \
    else printf("[FAIL] " name " (%d errors)\n", errors - sec_errors);

#define N 4  // 4 x 64-bit elements = 256-bit vector

int main() {
    if (snrt_global_core_idx() == 0) {
        int errors = 0;
        int sec_errors;

        int64_t  xi[N]     = {10, 20, 30, 40};
        int64_t  yi[N]     = { 3,  4,  5,  6};
        int64_t  xi_neg[N] = {-80, -60, -40, -20};
        uint64_t xu[N]     = {10, 20, 30, 40};
        int64_t  zi[N];

        int32_t  xi32[N] = { 3,  7, 11, 15};
        uint32_t xu32[N] = { 3,  7, 11, 15};

        int64_t  xs    = 5;
        uint64_t xu_s  = 5;
        int64_t  sa    = 2;
        int32_t  xs32  = 3;
        uint32_t xu32s = 3;

        int64_t ai64[N] = {100, 200, 300, 400};
        int64_t ai[N]   = {  1,   2,   3,   4};

        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N)); NOPS();

        // ================================================================
        // INTEGER VX ARITHMETIC (scalar integer operand)
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vadd.vx v8, v0, %0" :: "r"(xs)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));   NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != xi[i] + xs) { printf("vadd.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vsub.vx v8, v0, %0" :: "r"(xs)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));   NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != xi[i] - xs) { printf("vsub.vx error at %d\n", i); errors++; }

        // vrsub.vx: vd[i] = rs1 - vs2[i]
        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vrsub.vx v8, v0, %0" :: "r"(xs)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));    NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != xs - xi[i]) { printf("vrsub.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vand.vx v8, v0, %0" :: "r"(xs)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));   NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] & xs)) { printf("vand.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vor.vx v8, v0, %0" :: "r"(xs));  NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));   NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] | xs)) { printf("vor.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vxor.vx v8, v0, %0" :: "r"(xs)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));   NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] ^ xs)) { printf("vxor.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vmin.vx v8, v0, %0" :: "r"(xs)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));   NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] < xs ? xi[i] : xs)) { printf("vmin.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xu)); NOPS();
        asm volatile("vminu.vx v8, v0, %0" :: "r"(xu_s)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));      NOPS();
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != (xu[i] < xu_s ? xu[i] : xu_s)) { printf("vminu.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vmax.vx v8, v0, %0" :: "r"(xs)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));   NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] > xs ? xi[i] : xs)) { printf("vmax.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xu)); NOPS();
        asm volatile("vmaxu.vx v8, v0, %0" :: "r"(xu_s)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));      NOPS();
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != (xu[i] > xu_s ? xu[i] : xu_s)) { printf("vmaxu.vx error at %d\n", i); errors++; }

        SECTION_END("integer vx arithmetic (vadd/vsub/vrsub/vand/vor/vxor/vmin/vminu/vmax/vmaxu)");

        // ================================================================
        // INTEGER VX SHIFTS
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vsll.vx v8, v0, %0" :: "r"(sa)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));   NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] << sa)) { printf("vsll.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xu)); NOPS();
        asm volatile("vsrl.vx v8, v0, %0" :: "r"(sa)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));   NOPS();
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != (xu[i] >> sa)) { printf("vsrl.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi_neg)); NOPS();
        asm volatile("vsra.vx v8, v0, %0" :: "r"(sa));   NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));      NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi_neg[i] >> sa)) { printf("vsra.vx error at %d\n", i); errors++; }

        SECTION_END("integer vx shifts (vsll/vsrl/vsra)");

        // ================================================================
        // INTEGER VX MULTIPLY
        // ================================================================
        sec_errors = errors;

        // vmul.vx: low 64 bits
        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vmul.vx v8, v0, %0" :: "r"(xs)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));   NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != xi[i] * xs) { printf("vmul.vx error at %d\n", i); errors++; }

        // vmulh.vx / vmulhu.vx / vmulhsu.vx: high bits = 0 for small values
        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vmulh.vx v8, v0, %0" :: "r"(xs)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));    NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != 0) { printf("vmulh.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xu)); NOPS();
        asm volatile("vmulhu.vx v8, v0, %0" :: "r"(xu_s)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));       NOPS();
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != 0) { printf("vmulhu.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vmulhsu.vx v8, v0, %0" :: "r"(xu_s)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));        NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != 0) { printf("vmulhsu.vx error at %d\n", i); errors++; }

        SECTION_END("integer vx multiply (vmul/vmulh/vmulhu/vmulhsu)");

        // ================================================================
        // INTEGER VX DIVIDE / REMAINDER
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vdiv.vx v8, v0, %0" :: "r"(xs)); NOPS(); NOPS(); NOPS(); NOPS(); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));   NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != xi[i] / xs) { printf("vdiv.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xu)); NOPS();
        asm volatile("vdivu.vx v8, v0, %0" :: "r"(xu_s)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));      NOPS();
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != xu[i] / xu_s) { printf("vdivu.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vrem.vx v8, v0, %0" :: "r"(xs)); NOPS(); NOPS(); NOPS(); NOPS(); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));   NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != xi[i] % xs) { printf("vrem.vx error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xu)); NOPS();
        asm volatile("vremu.vx v8, v0, %0" :: "r"(xu_s)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));      NOPS();
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != xu[i] % xu_s) { printf("vremu.vx error at %d\n", i); errors++; }

        SECTION_END("integer vx divide/remainder (vdiv/vdivu/vrem/vremu)");

        // ================================================================
        // INTEGER VX WIDENING MULTIPLY (e32 -> e64)
        // ================================================================
        sec_errors = errors;

        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vle32.v v0, (%0)" :: "r"(xi32)); NOPS();
        asm volatile("vwmul.vx v8, v0, %0" :: "r"(xs32)); NOPS();
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));       NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (int64_t)xi32[i] * (int64_t)xs32) { printf("vwmul.vx error at %d\n", i); errors++; }

        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vle32.v v0, (%0)" :: "r"(xu32)); NOPS();
        asm volatile("vwmulu.vx v8, v0, %0" :: "r"(xu32s)); NOPS();
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));        NOPS();
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != (uint64_t)xu32[i] * (uint64_t)xu32s) { printf("vwmulu.vx error at %d\n", i); errors++; }

        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vle32.v v0, (%0)" :: "r"(xi32)); NOPS();
        asm volatile("vwmulsu.vx v8, v0, %0" :: "r"(xu32s)); NOPS();
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));         NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (int64_t)xi32[i] * (int64_t)xu32s) { printf("vwmulsu.vx error at %d\n", i); errors++; }

        SECTION_END("integer vx widening multiply (vwmul/vwmulu/vwmulsu)");

        // ================================================================
        // INTEGER VX WIDENING MULTIPLY-ACCUMULATE
        // ================================================================
        sec_errors = errors;

        // vwmacc.vx vd, rs1, vs2: vd[i](e64) += rs1(s32) * vs2[i](e32)
        asm volatile("vle64.v v8, (%0)" :: "r"(ai64)); NOPS();
        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vle32.v v0, (%0)" :: "r"(xi32)); NOPS();
        asm volatile("vwmacc.vx v8, %0, v0" :: "r"(xs32)); NOPS();
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));       NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != ai64[i] + (int64_t)xs32 * (int64_t)xi32[i]) { printf("vwmacc.vx error at %d\n", i); errors++; }

        // vwmaccu.vx: vd[i](e64) += rs1(u32) * vs2[i](e32,u)
        asm volatile("vle64.v v8, (%0)" :: "r"(ai64)); NOPS();
        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vle32.v v0, (%0)" :: "r"(xu32)); NOPS();
        asm volatile("vwmaccu.vx v8, %0, v0" :: "r"(xu32s)); NOPS();
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));        NOPS();
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != (uint64_t)ai64[i] + (uint64_t)xu32s * (uint64_t)xu32[i]) { printf("vwmaccu.vx error at %d\n", i); errors++; }

        // vwmaccsu.vx: vd[i](e64) += rs1(s32) * vs2[i](e32,u)
        asm volatile("vle64.v v8, (%0)" :: "r"(ai64)); NOPS();
        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vle32.v v0, (%0)" :: "r"(xu32)); NOPS();
        asm volatile("vwmaccsu.vx v8, %0, v0" :: "r"(xs32)); NOPS();
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));         NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != ai64[i] + (int64_t)xs32 * (int64_t)xu32[i]) { printf("vwmaccsu.vx error at %d\n", i); errors++; }

        // vwmaccus.vx: vd[i](e64) += rs1(u32) * vs2[i](e32,s)
        asm volatile("vle64.v v8, (%0)" :: "r"(ai64)); NOPS();
        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vle32.v v0, (%0)" :: "r"(xi32)); NOPS();
        asm volatile("vwmaccus.vx v8, %0, v0" :: "r"(xu32s)); NOPS();
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));          NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != ai64[i] + (int64_t)xu32s * (int64_t)xi32[i]) { printf("vwmaccus.vx error at %d\n", i); errors++; }

        SECTION_END("integer vx widening macc (vwmacc/vwmaccu/vwmaccsu/vwmaccus)");

        // ================================================================
        // INTEGER VX MULTIPLY-ACCUMULATE
        // ================================================================
        sec_errors = errors;

        // vmacc.vx vd, rs1, vs2: vd[i] += rs1 * vs2[i]
        asm volatile("vle64.v v8, (%0)" :: "r"(ai)); NOPS();
        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vmacc.vx v8, %0, v0" :: "r"(xs)); NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));    NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != ai[i] + xs * xi[i]) { printf("vmacc.vx error at %d\n", i); errors++; }

        SECTION_END("integer vx multiply-accumulate (vmacc.vx)");

        if (errors == 0)
            printf("All tests passed (int vx)\n");
        else
            printf("%d total errors\n", errors);
    }

    snrt_cluster_hw_barrier();
    return 0;
}
