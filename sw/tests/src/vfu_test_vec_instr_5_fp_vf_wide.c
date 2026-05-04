// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>
#include "snrt.h"

#define SECTION_END(name)            \
    if (errors == sec_errors)        \
        printf("[PASS] " name "\n"); \
    else                             \
        printf("[FAIL] " name " (%d errors)\n", errors - sec_errors);

#define N 4  // 4 x 64-bit elements = 256-bit vector

int main() {
    if (snrt_global_core_idx() == 0) {
        int errors = 0;
        int sec_errors;

        // FP e64 data
        double xf[N] = {1.0, 2.0, 3.0, 4.0};
        double yf[N] = {2.0, 3.0, 4.0, 5.0};
        double af[N] = {1.0, 1.0, 1.0, 1.0};
        double zf[N];

        // e32 FP widening sources
        float xf32[N] = {1.0f, 2.0f, 3.0f, 4.0f};
        float yf32[N] = {2.0f, 3.0f, 4.0f, 5.0f};
        double af64[N] = {10.0, 20.0, 30.0, 40.0};

        // Integer data for conversions
        int64_t xi[N] = {10, 20, 30, 40};
        uint64_t xu[N] = {10, 20, 30, 40};
        int64_t zi[N];

        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" ::"r"(N));

        // ================================================================
        // FP VF (vector-scalar float)
        // ================================================================
        sec_errors = errors;

        const double fs = 10.0;

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vfadd.vf v8, v0, %0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != xf[i] + fs) {
                printf("vfadd.vf error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vfsub.vf v8, v0, %0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != xf[i] - fs) {
                printf("vfsub.vf error at %d\n", i);
                errors++;
            }

        // vfrsub.vf: vd[i] = fs - vs2[i]
        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vfrsub.vf v8, v0, %0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != fs - xf[i]) {
                printf("vfrsub.vf error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vfmul.vf v8, v0, %0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != xf[i] * fs) {
                printf("vfmul.vf error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vfmin.vf v8, v0, %0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != (xf[i] < fs ? xf[i] : fs)) {
                printf("vfmin.vf error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vfmax.vf v8, v0, %0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != (xf[i] > fs ? xf[i] : fs)) {
                printf("vfmax.vf error at %d\n", i);
                errors++;
            }

        // vfsgnj.vf: magnitude of vs2, sign of fs (fs=10.0 positive => result = xf)
        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vfsgnj.vf v8, v0, %0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != xf[i]) {
                printf("vfsgnj.vf error at %d\n", i);
                errors++;
            }

        // vfsgnjn.vf: magnitude of vs2, negated sign of fs => result = -xf
        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vfsgnjn.vf v8, v0, %0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != -xf[i]) {
                printf("vfsgnjn.vf error at %d\n", i);
                errors++;
            }

        // vfsgnjx.vf: sign = sign(vs2) XOR sign(fs); both positive => result = xf
        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vfsgnjx.vf v8, v0, %0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != xf[i]) {
                printf("vfsgnjx.vf error at %d\n", i);
                errors++;
            }

        // vfmadd.vf: vd[i] = vd[i]*fs + vs2[i]
        asm volatile("vle64.v v0, (%0)" ::"r"(yf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfmadd.vf v8, %0, v0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != af[i] * fs + yf[i]) {
                printf("vfmadd.vf error at %d\n", i);
                errors++;
            }

        // vfmsub.vf: vd[i] = vd[i]*fs - vs2[i]
        asm volatile("vle64.v v0, (%0)" ::"r"(yf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfmsub.vf v8, %0, v0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != af[i] * fs - yf[i]) {
                printf("vfmsub.vf error at %d\n", i);
                errors++;
            }

        // vfnmadd.vf: vd[i] = -(vd[i]*fs) - vs2[i]
        asm volatile("vle64.v v0, (%0)" ::"r"(yf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfnmadd.vf v8, %0, v0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != -(af[i] * fs) - yf[i]) {
                printf("vfnmadd.vf error at %d\n", i);
                errors++;
            }

        // vfnmsub.vf: vd[i] = -(vd[i]*fs) + vs2[i]
        asm volatile("vle64.v v0, (%0)" ::"r"(yf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfnmsub.vf v8, %0, v0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != -(af[i] * fs) + yf[i]) {
                printf("vfnmsub.vf error at %d\n", i);
                errors++;
            }

        // vfmacc.vf: vd[i] = fs*vs2[i] + vd[i]
        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfmacc.vf v8, %0, v0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != fs * xf[i] + af[i]) {
                printf("vfmacc.vf error at %d\n", i);
                errors++;
            }

        // vfnmacc.vf: vd[i] = -(fs*vs2[i]) - vd[i]
        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfnmacc.vf v8, %0, v0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != -(fs * xf[i]) - af[i]) {
                printf("vfnmacc.vf error at %d\n", i);
                errors++;
            }

        // vfmsac.vf: vd[i] = fs*vs2[i] - vd[i]
        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfmsac.vf v8, %0, v0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != fs * xf[i] - af[i]) {
                printf("vfmsac.vf error at %d\n", i);
                errors++;
            }

        // vfnmsac.vf: vd[i] = -(fs*vs2[i]) - vd[i]
        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vle64.v v8, (%0)" ::"r"(af));
        asm volatile("vfnmsac.vf v8, %0, v0" ::"f"(fs));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != -(fs * xf[i]) + af[i]) {
                printf("vfnmsac.vf error at %d\n", i);
                errors++;
            }

        SECTION_END(
            "fp vf "
            "(vfadd/vfsub/vfrsub/vfmul/vfmin/vfmax/vfsgnj*/vfmadd/vfmsub/"
            "vfnmadd/vfnmsub/vfmacc/vfnmacc/vfmsac/vfnmsac)");

        // ================================================================
        // FP VV WIDENING (f32 source -> f64 destination)
        // ================================================================
        sec_errors = errors;

        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" ::"r"(N));
        asm volatile("vle32.v v0, (%0)" ::"r"(xf32));
        asm volatile("vle32.v v4, (%0)" ::"r"(yf32));
        asm volatile("vfwadd.vv v8, v0, v4");
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" ::"r"(N));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != (double)xf32[i] + (double)yf32[i]) {
                printf("vfwadd error at %d\n", i);
                errors++;
            }

        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" ::"r"(N));
        asm volatile("vle32.v v0, (%0)" ::"r"(xf32));
        asm volatile("vle32.v v4, (%0)" ::"r"(yf32));
        asm volatile("vfwsub.vv v8, v0, v4");
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" ::"r"(N));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != (double)xf32[i] - (double)yf32[i]) {
                printf("vfwsub error at %d\n", i);
                errors++;
            }

        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" ::"r"(N));
        asm volatile("vle32.v v0, (%0)" ::"r"(xf32));
        asm volatile("vle32.v v4, (%0)" ::"r"(yf32));
        asm volatile("vfwmul.vv v8, v0, v4");
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" ::"r"(N));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != (double)xf32[i] * (double)yf32[i]) {
                printf("vfwmul error at %d\n", i);
                errors++;
            }

        // vfwmacc.vv: vd[i](f64) += vs1[i](f32) * vs2[i](f32)
        asm volatile("vle64.v v8, (%0)" ::"r"(af64));
        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" ::"r"(N));
        asm volatile("vle32.v v0, (%0)" ::"r"(xf32));
        asm volatile("vle32.v v4, (%0)" ::"r"(yf32));
        asm volatile("vfwmacc.vv v8, v0, v4");
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" ::"r"(N));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != af64[i] + (double)xf32[i] * (double)yf32[i]) {
                printf("vfwmacc error at %d\n", i);
                errors++;
            }

        // vfwnmacc.vv: vd[i](f64) = -(vs1[i]*vs2[i]) - vd[i]
        asm volatile("vle64.v v8, (%0)" ::"r"(af64));
        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" ::"r"(N));
        asm volatile("vle32.v v0, (%0)" ::"r"(xf32));
        asm volatile("vle32.v v4, (%0)" ::"r"(yf32));
        asm volatile("vfwnmacc.vv v8, v0, v4");
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" ::"r"(N));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != -((double)xf32[i] * (double)yf32[i]) - af64[i]) {
                printf("vfwnmacc error at %d\n", i);
                errors++;
            }

        // vfwmsac.vv: vd[i](f64) = vs1[i]*vs2[i] - vd[i]
        asm volatile("vle64.v v8, (%0)" ::"r"(af64));
        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" ::"r"(N));
        asm volatile("vle32.v v0, (%0)" ::"r"(xf32));
        asm volatile("vle32.v v4, (%0)" ::"r"(yf32));
        asm volatile("vfwmsac.vv v8, v0, v4");
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" ::"r"(N));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != (double)xf32[i] * (double)yf32[i] - af64[i]) {
                printf("vfwmsac error at %d\n", i);
                errors++;
            }

        // vfwnmsac.vv: vd[i](f64) = -(vs1[i]*vs2[i]) + vd[i]
        asm volatile("vle64.v v8, (%0)" ::"r"(af64));
        asm volatile("vsetvli zero, %0, e32, m1, ta, ma" ::"r"(N));
        asm volatile("vle32.v v0, (%0)" ::"r"(xf32));
        asm volatile("vle32.v v4, (%0)" ::"r"(yf32));
        asm volatile("vfwnmsac.vv v8, v0, v4");
        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" ::"r"(N));
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != -((double)xf32[i] * (double)yf32[i]) + af64[i]) {
                printf("vfwnmsac error at %d\n", i);
                errors++;
            }

        SECTION_END(
            "fp vv widening "
            "(vfwadd/vfwsub/vfwmul/vfwmacc/vfwnmacc/vfwmsac/vfwnmsac)");

        // ================================================================
        // FP CONVERSIONS
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" ::"r"(xi));
        asm volatile("vfcvt.f.x.v v8, v0");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != (double)xi[i]) {
                printf("vfcvt.f.x error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vfcvt.x.f.v v8, v0");
        asm volatile("vse64.v v8, (%0)" ::"r"(zi));
        for (int i = 0; i < N; i++)
            if ((double)zi[i] != xf[i]) {
                printf("vfcvt.x.f error at %d\n", i);
                errors++;
            }

        asm volatile("vle64.v v0, (%0)" ::"r"(xu));
        asm volatile("vfcvt.f.xu.v v8, v0");
        asm volatile("vse64.v v8, (%0)" ::"r"(zf));
        for (int i = 0; i < N; i++)
            if (zf[i] != (double)xu[i]) {
                printf("vfcvt.f.xu error at %d\n", i);
                errors++;
            }

        uint64_t zu[4] = {0};
        asm volatile("vle64.v v0, (%0)" ::"r"(xf));
        asm volatile("vfcvt.xu.f.v v8, v0");
        asm volatile("vse64.v v8, (%0)" ::"r"(zu));
        for (int i = 0; i < N; i++)
            if ((double)zu[i] != xf[i]) {
                printf("vfcvt.xu.f error at %d\n", i);
                errors++;
            }

        SECTION_END(
            "fp conversions (vfcvt.f.x/vfcvt.x.f/vfcvt.f.xu/vfcvt.xu.f)");

        if (errors == 0)
            printf("All tests passed (fp vf + widening + conversions)\n");
        else
            printf("%d total errors\n", errors);
    }

    snrt_cluster_hw_barrier();
    return 0;
}