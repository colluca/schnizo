// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Reduction tests for schnizo (VLEN=256 fixed-vl SIMD).
// Each test case uses exactly VLEN/SEW elements so no zero-padding or
// vl-truncation can change the result.

#include "vector_macros.h"

// ?? vredsum ???????????????????????????????????????????????????????????????????

void TEST_vredsum(void) {
  // e8: vl=32, scalar 1, 32×1 ? sum = 1+32 = 33
  VSET(32, e8, m1);
  VLOAD_8(v16, 1, 1, 1, 1, 1, 1, 1, 1,
              1, 1, 1, 1, 1, 1, 1, 1,
              1, 1, 1, 1, 1, 1, 1, 1,
              1, 1, 1, 1, 1, 1, 1, 1);
  VLOAD_8(v8, 1);
  asm volatile("vredsum.vs v24, v16, v8");
  VCMP_U8(1, v24, 33);

  // e16: vl=16, scalar 0, 1..16 ? sum = 136
  VSET(16, e16, m1);
  VLOAD_16(v16, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16);
  VLOAD_16(v8, 0);
  asm volatile("vredsum.vs v24, v16, v8");
  VCMP_U16(2, v24, 136);

  // e32: vl=8, scalar 1, 1..8 ? sum = 1+36 = 37
  VSET(8, e32, m1);
  VLOAD_32(v16, 1, 2, 3, 4, 5, 6, 7, 8);
  VLOAD_32(v8, 1);
  asm volatile("vredsum.vs v24, v16, v8");
  VCMP_U32(3, v24, 37);

#if ELEN == 64
  // e64: vl=4, scalar 0, 1..4 ? sum = 10
  VSET(4, e64, m1);
  VLOAD_64(v16, 1, 2, 3, 4);
  VLOAD_64(v8, 0);
  asm volatile("vredsum.vs v24, v16, v8");
  VCMP_U64(4, v24, 10);
#endif
}

// ?? vredand ???????????????????????????????????????????????????????????????????

void TEST_vredand(void) {
  // e8: 32×0xff, scalar 0xf0 ? 0xff & 0xf0 = 0xf0
  VSET(32, e8, m1);
  VLOAD_8(v16, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
              0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
              0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
              0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff);
  VLOAD_8(v8, 0xf0);
  asm volatile("vredand.vs v24, v16, v8");
  VCMP_U8(1, v24, 0xf0);

  // e16: 15×0xffff and 0x00ff, scalar 0xffff ? 0x00ff
  VSET(16, e16, m1);
  VLOAD_16(v16, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff,
               0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0x00ff);
  VLOAD_16(v8, 0xffff);
  asm volatile("vredand.vs v24, v16, v8");
  VCMP_U16(2, v24, 0x00ff);

  // e32: 7×0xffffffff and 0x0f0f0f0f, scalar 0xffffffff ? 0x0f0f0f0f
  VSET(8, e32, m1);
  VLOAD_32(v16, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
               0xffffffff, 0xffffffff, 0xffffffff, 0x0f0f0f0f);
  VLOAD_32(v8, 0xffffffff);
  asm volatile("vredand.vs v24, v16, v8");
  VCMP_U32(3, v24, 0x0f0f0f0f);

#if ELEN == 64
  // e64: 3×0xffffffffffffffff and 0x0123456789abcdef ? 0x0123456789abcdef
  VSET(4, e64, m1);
  VLOAD_64(v16, 0xffffffffffffffff, 0xffffffffffffffff,
               0xffffffffffffffff, 0x0123456789abcdef);
  VLOAD_64(v8, 0xffffffffffffffff);
  asm volatile("vredand.vs v24, v16, v8");
  VCMP_U64(4, v24, 0x0123456789abcdef);
#endif
}

// ?? vredor ????????????????????????????????????????????????????????????????????

void TEST_vredor(void) {
  // e8: {0x01,0x02}×16, scalar 0 ? 0x03
  VSET(32, e8, m1);
  VLOAD_8(v16, 0x01, 0x02, 0x01, 0x02, 0x01, 0x02, 0x01, 0x02,
              0x01, 0x02, 0x01, 0x02, 0x01, 0x02, 0x01, 0x02,
              0x01, 0x02, 0x01, 0x02, 0x01, 0x02, 0x01, 0x02,
              0x01, 0x02, 0x01, 0x02, 0x01, 0x02, 0x01, 0x02);
  VLOAD_8(v8, 0);
  asm volatile("vredor.vs v24, v16, v8");
  VCMP_U8(1, v24, 0x03);

  // e16: {0x0001,0x0100}×8, scalar 0 ? 0x0101
  VSET(16, e16, m1);
  VLOAD_16(v16, 0x0001, 0x0100, 0x0001, 0x0100, 0x0001, 0x0100, 0x0001, 0x0100,
               0x0001, 0x0100, 0x0001, 0x0100, 0x0001, 0x0100, 0x0001, 0x0100);
  VLOAD_16(v8, 0);
  asm volatile("vredor.vs v24, v16, v8");
  VCMP_U16(2, v24, 0x0101);

  // e32: {0x00000001,0x00010000}×4, scalar 0 ? 0x00010001
  VSET(8, e32, m1);
  VLOAD_32(v16, 0x00000001, 0x00010000, 0x00000001, 0x00010000,
               0x00000001, 0x00010000, 0x00000001, 0x00010000);
  VLOAD_32(v8, 0);
  asm volatile("vredor.vs v24, v16, v8");
  VCMP_U32(3, v24, 0x00010001);

#if ELEN == 64
  // e64: {0x0000000000000001,0x0000000100000000}×2, scalar 0 ? 0x0000000100000001
  VSET(4, e64, m1);
  VLOAD_64(v16, 0x0000000000000001, 0x0000000100000000,
               0x0000000000000001, 0x0000000100000000);
  VLOAD_64(v8, 0);
  asm volatile("vredor.vs v24, v16, v8");
  VCMP_U64(4, v24, 0x0000000100000001);
#endif
}

// ?? vredxor ???????????????????????????????????????????????????????????????????

void TEST_vredxor(void) {
  // e8: 31×0x55 and 0xaa, scalar 0 ? 0x55 (odd)^0xaa = 0xff
  VSET(32, e8, m1);
  VLOAD_8(v16, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
              0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
              0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
              0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0xaa);
  VLOAD_8(v8, 0);
  asm volatile("vredxor.vs v24, v16, v8");
  VCMP_U8(1, v24, 0xff);

  // e16: 15×0x5555 and 0xaaaa, scalar 0 ? 0xffff
  VSET(16, e16, m1);
  VLOAD_16(v16, 0x5555, 0x5555, 0x5555, 0x5555, 0x5555, 0x5555, 0x5555, 0x5555,
               0x5555, 0x5555, 0x5555, 0x5555, 0x5555, 0x5555, 0x5555, 0xaaaa);
  VLOAD_16(v8, 0);
  asm volatile("vredxor.vs v24, v16, v8");
  VCMP_U16(2, v24, 0xffff);

  // e32: 7×0x55555555 and 0xaaaaaaaa, scalar 0 ? 0xffffffff
  VSET(8, e32, m1);
  VLOAD_32(v16, 0x55555555, 0x55555555, 0x55555555, 0x55555555,
               0x55555555, 0x55555555, 0x55555555, 0xaaaaaaaa);
  VLOAD_32(v8, 0);
  asm volatile("vredxor.vs v24, v16, v8");
  VCMP_U32(3, v24, 0xffffffff);

#if ELEN == 64
  // e64: 3×0x5555555555555555 and 0xaaaaaaaaaaaaaaaa ? 0xffffffffffffffff
  VSET(4, e64, m1);
  VLOAD_64(v16, 0x5555555555555555, 0x5555555555555555,
               0x5555555555555555, 0xaaaaaaaaaaaaaaaa);
  VLOAD_64(v8, 0);
  asm volatile("vredxor.vs v24, v16, v8");
  VCMP_U64(4, v24, 0xffffffffffffffff);
#endif
}

// ?? vredmin ???????????????????????????????????????????????????????????????????

void TEST_vredmin(void) {
  // e8 (signed): 31×5 and -10, scalar 0 ? -10
  VSET(32, e8, m1);
  VLOAD_8(v16, 5, 5, 5, 5, 5, 5, 5, 5,
              5, 5, 5, 5, 5, 5, 5, 5,
              5, 5, 5, 5, 5, 5, 5, 5,
              5, 5, 5, 5, 5, 5, 5, -10);
  VLOAD_8(v8, 0);
  asm volatile("vredmin.vs v24, v16, v8");
  VCMP_U8(1, v24, -10);

  // e16: 15×100 and -50, scalar 0 ? -50
  VSET(16, e16, m1);
  VLOAD_16(v16, 100, 100, 100, 100, 100, 100, 100, 100,
               100, 100, 100, 100, 100, 100, 100, -50);
  VLOAD_16(v8, 0);
  asm volatile("vredmin.vs v24, v16, v8");
  VCMP_U16(2, v24, -50);

  // e32: {7,6,5,4,3,2,1,-8}, scalar 0 ? -8
  VSET(8, e32, m1);
  VLOAD_32(v16, 7, 6, 5, 4, 3, 2, 1, -8);
  VLOAD_32(v8, 0);
  asm volatile("vredmin.vs v24, v16, v8");
  VCMP_U32(3, v24, -8);

#if ELEN == 64
  // e64: {9,8,-7,6}, scalar 0 ? -7
  VSET(4, e64, m1);
  VLOAD_64(v16, 9, 8, -7, 6);
  VLOAD_64(v8, 0);
  asm volatile("vredmin.vs v24, v16, v8");
  VCMP_U64(4, v24, -7);
#endif
}

// ?? vredminu ??????????????????????????????????????????????????????????????????

void TEST_vredminu(void) {
  // e8: 31×10 and 3, scalar 255 ? 3
  VSET(32, e8, m1);
  VLOAD_8(v16, 10, 10, 10, 10, 10, 10, 10, 10,
              10, 10, 10, 10, 10, 10, 10, 10,
              10, 10, 10, 10, 10, 10, 10, 10,
              10, 10, 10, 10, 10, 10, 10, 3);
  VLOAD_8(v8, 255);
  asm volatile("vredminu.vs v24, v16, v8");
  VCMP_U8(1, v24, 3);

  // e16: 15×100 and 50, scalar 200 ? 50
  VSET(16, e16, m1);
  VLOAD_16(v16, 100, 100, 100, 100, 100, 100, 100, 100,
               100, 100, 100, 100, 100, 100, 100, 50);
  VLOAD_16(v8, 200);
  asm volatile("vredminu.vs v24, v16, v8");
  VCMP_U16(2, v24, 50);

  // e32: {9,8,7,6,5,4,3,2}, scalar 10 ? 2
  VSET(8, e32, m1);
  VLOAD_32(v16, 9, 8, 7, 6, 5, 4, 3, 2);
  VLOAD_32(v8, 10);
  asm volatile("vredminu.vs v24, v16, v8");
  VCMP_U32(3, v24, 2);

#if ELEN == 64
  // e64: {9,8,7,6}, scalar 10 ? 6
  VSET(4, e64, m1);
  VLOAD_64(v16, 9, 8, 7, 6);
  VLOAD_64(v8, 10);
  asm volatile("vredminu.vs v24, v16, v8");
  VCMP_U64(4, v24, 6);
#endif
}

// ?? vredmax ???????????????????????????????????????????????????????????????????

void TEST_vredmax(void) {
  // e8 (signed): 31×(-5) and 10, scalar -100 ? 10
  VSET(32, e8, m1);
  VLOAD_8(v16, -5, -5, -5, -5, -5, -5, -5, -5,
              -5, -5, -5, -5, -5, -5, -5, -5,
              -5, -5, -5, -5, -5, -5, -5, -5,
              -5, -5, -5, -5, -5, -5, -5, 10);
  VLOAD_8(v8, -100);
  asm volatile("vredmax.vs v24, v16, v8");
  VCMP_U8(1, v24, 10);

  // e16: 15×(-1) and 50, scalar -100 ? 50
  VSET(16, e16, m1);
  VLOAD_16(v16, -1, -1, -1, -1, -1, -1, -1, -1,
               -1, -1, -1, -1, -1, -1, -1, 50);
  VLOAD_16(v8, -100);
  asm volatile("vredmax.vs v24, v16, v8");
  VCMP_U16(2, v24, 50);

  // e32: {-1,-2,-3,-4,-5,-6,-7,9}, scalar -1 ? 9
  VSET(8, e32, m1);
  VLOAD_32(v16, -1, -2, -3, -4, -5, -6, -7, 9);
  VLOAD_32(v8, -1);
  asm volatile("vredmax.vs v24, v16, v8");
  VCMP_U32(3, v24, 9);

#if ELEN == 64
  // e64: {-1,-2,7,-4}, scalar -1 ? 7
  VSET(4, e64, m1);
  VLOAD_64(v16, -1, -2, 7, -4);
  VLOAD_64(v8, -1);
  asm volatile("vredmax.vs v24, v16, v8");
  VCMP_U64(4, v24, 7);
#endif
}

// ?? vredmaxu ??????????????????????????????????????????????????????????????????

void TEST_vredmaxu(void) {
  // e8: 31×1 and 200, scalar 0 ? 200
  VSET(32, e8, m1);
  VLOAD_8(v16, 1, 1, 1, 1, 1, 1, 1, 1,
              1, 1, 1, 1, 1, 1, 1, 1,
              1, 1, 1, 1, 1, 1, 1, 1,
              1, 1, 1, 1, 1, 1, 1, 200);
  VLOAD_8(v8, 0);
  asm volatile("vredmaxu.vs v24, v16, v8");
  VCMP_U8(1, v24, 200);

  // e16: 15×100 and 500, scalar 10 ? 500
  VSET(16, e16, m1);
  VLOAD_16(v16, 100, 100, 100, 100, 100, 100, 100, 100,
               100, 100, 100, 100, 100, 100, 100, 500);
  VLOAD_16(v8, 10);
  asm volatile("vredmaxu.vs v24, v16, v8");
  VCMP_U16(2, v24, 500);

  // e32: {1,2,3,4,5,6,7,100}, scalar 0 ? 100
  VSET(8, e32, m1);
  VLOAD_32(v16, 1, 2, 3, 4, 5, 6, 7, 100);
  VLOAD_32(v8, 0);
  asm volatile("vredmaxu.vs v24, v16, v8");
  VCMP_U32(3, v24, 100);

#if ELEN == 64
  // e64: {1,2,3,4}, scalar 0 ? 4
  VSET(4, e64, m1);
  VLOAD_64(v16, 1, 2, 3, 4);
  VLOAD_64(v8, 0);
  asm volatile("vredmaxu.vs v24, v16, v8");
  VCMP_U64(4, v24, 4);
#endif
}

// ?? vfredmin ??????????????????????????????????????????????????????????????????
// fp16: 1.0=0x3c00, 8.0=0x4800, 9.0=0x4880
// fp32: 1.0=0x3F800000, 8.0=0x41000000, 10.0=0x41200000
// fp64: 1.0=0x3FF0000000000000, 8.0=0x4020000000000000, 10.0=0x4024000000000000

void TEST_vfredmin(void) {
  // e16: vl=16, 15×8.0 and 1.0, scalar 9.0 ? min=1.0
  VSET(16, e16, m1);
  VLOAD_16(v16, 0x4800, 0x4800, 0x4800, 0x4800, 0x4800, 0x4800, 0x4800, 0x4800,
               0x4800, 0x4800, 0x4800, 0x4800, 0x4800, 0x4800, 0x4800, 0x3c00);
  VLOAD_16(v24, 0x4880);
  asm volatile("vfredmin.vs v8, v16, v24");
  VCMP_U16(1, v8, 0x3c00);

  // e32: vl=8, 7×8.0 and 1.0, scalar 10.0 ? min=1.0
  VSET(8, e32, m1);
  VLOAD_32(v16, 0x41000000, 0x41000000, 0x41000000, 0x41000000,
               0x41000000, 0x41000000, 0x41000000, 0x3F800000);
  VLOAD_32(v24, 0x41200000);
  asm volatile("vfredmin.vs v8, v16, v24");
  VCMP_U32(2, v8, 0x3F800000);

#if ELEN == 64
  // e64: vl=4, 3×8.0 and 1.0, scalar 10.0 ? min=1.0
  VSET(4, e64, m1);
  VLOAD_64(v16, 0x4020000000000000, 0x4020000000000000,
               0x4020000000000000, 0x3FF0000000000000);
  VLOAD_64(v24, 0x4024000000000000);
  asm volatile("vfredmin.vs v8, v16, v24");
  VCMP_U64(3, v8, 0x3FF0000000000000);
#endif
}

// ?? vfredmax ??????????????????????????????????????????????????????????????????
// fp16: 0.5=0x3800, 1.0=0x3c00, 8.0=0x4800
// fp32: 0.5=0x3F000000, 1.0=0x3F800000, 8.0=0x41000000
// fp64: 0.5=0x3FE0000000000000, 1.0=0x3FF0000000000000, 8.0=0x4020000000000000

void TEST_vfredmax(void) {
  // e16: vl=16, 15×1.0 and 8.0, scalar 0.5 ? max=8.0
  VSET(16, e16, m1);
  VLOAD_16(v16, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00,
               0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x4800);
  VLOAD_16(v24, 0x3800);
  asm volatile("vfredmax.vs v8, v16, v24");
  VCMP_U16(1, v8, 0x4800);

  // e32: vl=8, 7×1.0 and 8.0, scalar 0.5 ? max=8.0
  VSET(8, e32, m1);
  VLOAD_32(v16, 0x3F800000, 0x3F800000, 0x3F800000, 0x3F800000,
               0x3F800000, 0x3F800000, 0x3F800000, 0x41000000);
  VLOAD_32(v24, 0x3F000000);
  asm volatile("vfredmax.vs v8, v16, v24");
  VCMP_U32(2, v8, 0x41000000);

#if ELEN == 64
  // e64: vl=4, 3×1.0 and 8.0, scalar 0.5 ? max=8.0
  VSET(4, e64, m1);
  VLOAD_64(v16, 0x3FF0000000000000, 0x3FF0000000000000,
               0x3FF0000000000000, 0x4020000000000000);
  VLOAD_64(v24, 0x3FE0000000000000);
  asm volatile("vfredmax.vs v8, v16, v24");
  VCMP_U64(3, v8, 0x4020000000000000);
#endif
}

// ?? vfredosum ?????????????????????????????????????????????????????????????????
// fp16: 0.0=0x0000, 1.0=0x3c00, 16.0=0x4c00
// fp32: 0.0=0x00000000, 1.0=0x3F800000, 8.0=0x41000000
// fp64: 0.0=0x0, 1.0=0x3FF0000000000000, 4.0=0x4010000000000000

void TEST_vfredosum(void) {
  // e16: 16×1.0, scalar 0.0 ? sum=16.0
  VSET(16, e16, m1);
  VLOAD_16(v16, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00,
               0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00);
  VLOAD_16(v24, 0x0000);
  asm volatile("vfredosum.vs v8, v16, v24");
  VCMP_U16(1, v8, 0x4c00);

  // e32: 8×1.0, scalar 0.0 ? sum=8.0
  VSET(8, e32, m1);
  VLOAD_32(v16, 0x3F800000, 0x3F800000, 0x3F800000, 0x3F800000,
               0x3F800000, 0x3F800000, 0x3F800000, 0x3F800000);
  VLOAD_32(v24, 0x00000000);
  asm volatile("vfredosum.vs v8, v16, v24");
  VCMP_U32(2, v8, 0x41000000);

#if ELEN == 64
  // e64: 4×1.0, scalar 0.0 ? sum=4.0
  VSET(4, e64, m1);
  VLOAD_64(v16, 0x3FF0000000000000, 0x3FF0000000000000,
               0x3FF0000000000000, 0x3FF0000000000000);
  VLOAD_64(v24, 0x0000000000000000);
  asm volatile("vfredosum.vs v8, v16, v24");
  VCMP_U64(3, v8, 0x4010000000000000);
#endif
}

// ?? vfredusum ?????????????????????????????????????????????????????????????????

void TEST_vfredusum(void) {
  // e16: 16×1.0, scalar 0.0 ? sum=16.0
  VSET(16, e16, m1);
  VLOAD_16(v16, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00,
               0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00);
  VLOAD_16(v24, 0x0000);
  asm volatile("vfredusum.vs v8, v16, v24");
  VCMP_U16(1, v8, 0x4c00);

  // e32: 8×1.0, scalar 0.0 ? sum=8.0
  VSET(8, e32, m1);
  VLOAD_32(v16, 0x3F800000, 0x3F800000, 0x3F800000, 0x3F800000,
               0x3F800000, 0x3F800000, 0x3F800000, 0x3F800000);
  VLOAD_32(v24, 0x00000000);
  asm volatile("vfredusum.vs v8, v16, v24");
  VCMP_U32(2, v8, 0x41000000);

#if ELEN == 64
  // e64: 4×1.0, scalar 0.0 ? sum=4.0
  VSET(4, e64, m1);
  VLOAD_64(v16, 0x3FF0000000000000, 0x3FF0000000000000,
               0x3FF0000000000000, 0x3FF0000000000000);
  VLOAD_64(v24, 0x0000000000000000);
  asm volatile("vfredusum.vs v8, v16, v24");
  VCMP_U64(3, v8, 0x4010000000000000);
#endif
}

// ?? vslideup ??????????????????????????????????????????????????????????????????
// All cases use exactly VLEN/SEW elements (one 256-bit word).
// dst is pre-loaded with 0xff pattern; src with 1,2,3,...
// After vslideup.vi vd,vs2,offset: vd[0..offset-1] unchanged, vd[offset..vl-1]=vs2[0..vl-1-offset]

void TEST_vslideup(void) {
  // e8: vl=32, offset=3 ? vd[0..2]=-1, vd[3..31]=src[0..28]={1..29}
  VSET(32, e8, m1);
  VLOAD_8(v8,  -1, -1, -1, -1, -1, -1, -1, -1,
               -1, -1, -1, -1, -1, -1, -1, -1,
               -1, -1, -1, -1, -1, -1, -1, -1,
               -1, -1, -1, -1, -1, -1, -1, -1);
  VLOAD_8(v16,  1,  2,  3,  4,  5,  6,  7,  8,
                9, 10, 11, 12, 13, 14, 15, 16,
               17, 18, 19, 20, 21, 22, 23, 24,
               25, 26, 27, 28, 29, 30, 31, 32);
  asm volatile("vslideup.vi v8, v16, 3");
  VCMP_U8(1, v8, -1, -1, -1,  1,  2,  3,  4,  5,
                  6,  7,  8,  9, 10, 11, 12, 13,
                 14, 15, 16, 17, 18, 19, 20, 21,
                 22, 23, 24, 25, 26, 27, 28, 29);

  // e16: vl=16, offset=4 ? vd[0..3]=-1, vd[4..15]=src[0..11]={1..12}
  VSET(16, e16, m1);
  VLOAD_16(v8,  -1, -1, -1, -1, -1, -1, -1, -1,
                -1, -1, -1, -1, -1, -1, -1, -1);
  VLOAD_16(v16,  1,  2,  3,  4,  5,  6,  7,  8,
                 9, 10, 11, 12, 13, 14, 15, 16);
  asm volatile("vslideup.vi v8, v16, 4");
  VCMP_U16(2, v8, -1, -1, -1, -1,  1,  2,  3,  4,
                   5,  6,  7,  8,  9, 10, 11, 12);

  // e32: vl=8, offset=2 ? vd[0..1]=-1, vd[2..7]=src[0..5]={1..6}
  VSET(8, e32, m1);
  VLOAD_32(v8,  -1, -1, -1, -1, -1, -1, -1, -1);
  VLOAD_32(v16,  1,  2,  3,  4,  5,  6,  7,  8);
  asm volatile("vslideup.vi v8, v16, 2");
  VCMP_U32(3, v8, -1, -1,  1,  2,  3,  4,  5,  6);

#if ELEN == 64
  // e64: vl=4, offset=1 ? vd[0]=-1, vd[1..3]=src[0..2]={1,2,3}
  VSET(4, e64, m1);
  VLOAD_64(v8,  -1, -1, -1, -1);
  VLOAD_64(v16,  1,  2,  3,  4);
  asm volatile("vslideup.vi v8, v16, 1");
  VCMP_U64(4, v8, -1,  1,  2,  3);
#endif
}

// ?? vslidedown ????????????????????????????????????????????????????????????????
// vslidedown.vi vd,vs2,offset: vd[i]=vs2[i+offset] (0 for i+offset>=vl)

void TEST_vslidedown(void) {
  // e8: vl=32, offset=3 ? vd[0..28]=src[3..31], vd[29..31]=0
  VSET(32, e8, m1);
  VLOAD_8(v16,  1,  2,  3,  4,  5,  6,  7,  8,
                9, 10, 11, 12, 13, 14, 15, 16,
               17, 18, 19, 20, 21, 22, 23, 24,
               25, 26, 27, 28, 29, 30, 31, 32);
  asm volatile("vslidedown.vi v8, v16, 3");
  VCMP_U8(1, v8,  4,  5,  6,  7,  8,  9, 10, 11,
                 12, 13, 14, 15, 16, 17, 18, 19,
                 20, 21, 22, 23, 24, 25, 26, 27,
                 28, 29, 30, 31, 32,  0,  0,  0);

  // e16: vl=16, offset=4 ? vd[0..11]=src[4..15], vd[12..15]=0
  VSET(16, e16, m1);
  VLOAD_16(v16,  1,  2,  3,  4,  5,  6,  7,  8,
                 9, 10, 11, 12, 13, 14, 15, 16);
  asm volatile("vslidedown.vi v8, v16, 4");
  VCMP_U16(2, v8,  5,  6,  7,  8,  9, 10, 11, 12,
                  13, 14, 15, 16,  0,  0,  0,  0);

  // e32: vl=8, offset=2 ? vd[0..5]=src[2..7], vd[6..7]=0
  VSET(8, e32, m1);
  VLOAD_32(v16,  1,  2,  3,  4,  5,  6,  7,  8);
  asm volatile("vslidedown.vi v8, v16, 2");
  VCMP_U32(3, v8,  3,  4,  5,  6,  7,  8,  0,  0);

#if ELEN == 64
  // e64: vl=4, offset=1 ? vd[0..2]=src[1..3], vd[3]=0
  VSET(4, e64, m1);
  VLOAD_64(v16,  1,  2,  3,  4);
  asm volatile("vslidedown.vi v8, v16, 1");
  VCMP_U64(4, v8,  2,  3,  4,  0);
#endif
}

// ?? vslide1up ?????????????????????????????????????????????????????????????????
// vslide1up.vx vd,vs2,rs1: vd[0]=rs1, vd[i]=vs2[i-1] for i>=1

void TEST_vslide1up(void) {
  // e8: vl=32, rs1=99 ? vd[0]=99, vd[1..31]=src[0..30]={1..31}
  VSET(32, e8, m1);
  VLOAD_8(v8,  -1, -1, -1, -1, -1, -1, -1, -1,
               -1, -1, -1, -1, -1, -1, -1, -1,
               -1, -1, -1, -1, -1, -1, -1, -1,
               -1, -1, -1, -1, -1, -1, -1, -1);
  VLOAD_8(v16,  1,  2,  3,  4,  5,  6,  7,  8,
                9, 10, 11, 12, 13, 14, 15, 16,
               17, 18, 19, 20, 21, 22, 23, 24,
               25, 26, 27, 28, 29, 30, 31, 32);
  asm volatile("vslide1up.vx v8, v16, %[rs]" :: [rs]"r"((long)99));
  VCMP_U8(1, v8, 99,  1,  2,  3,  4,  5,  6,  7,
                  8,  9, 10, 11, 12, 13, 14, 15,
                 16, 17, 18, 19, 20, 21, 22, 23,
                 24, 25, 26, 27, 28, 29, 30, 31);

  // e32: vl=8, rs1=42 ? vd[0]=42, vd[1..7]=src[0..6]={1..7}
  VSET(8, e32, m1);
  VLOAD_32(v8,  -1, -1, -1, -1, -1, -1, -1, -1);
  VLOAD_32(v16,  1,  2,  3,  4,  5,  6,  7,  8);
  asm volatile("vslide1up.vx v8, v16, %[rs]" :: [rs]"r"((long)42));
  VCMP_U32(2, v8, 42,  1,  2,  3,  4,  5,  6,  7);

#if ELEN == 64
  // e64: vl=4, rs1=77 ? vd[0]=77, vd[1..3]=src[0..2]={1,2,3}
  VSET(4, e64, m1);
  VLOAD_64(v8,  -1, -1, -1, -1);
  VLOAD_64(v16,  1,  2,  3,  4);
  asm volatile("vslide1up.vx v8, v16, %[rs]" :: [rs]"r"((long)77));
  VCMP_U64(3, v8, 77,  1,  2,  3);
#endif
}

// ?? vslide1down ???????????????????????????????????????????????????????????????
// vslide1down.vx vd,vs2,rs1: vd[vl-1]=rs1, vd[i]=vs2[i+1] for i<vl-1

void TEST_vslide1down(void) {
  // e8: vl=32, rs1=99 ? vd[0..30]=src[1..31]={2..32}, vd[31]=99
  VSET(32, e8, m1);
  VLOAD_8(v16,  1,  2,  3,  4,  5,  6,  7,  8,
                9, 10, 11, 12, 13, 14, 15, 16,
               17, 18, 19, 20, 21, 22, 23, 24,
               25, 26, 27, 28, 29, 30, 31, 32);
  asm volatile("vslide1down.vx v8, v16, %[rs]" :: [rs]"r"((long)99));
  VCMP_U8(1, v8,  2,  3,  4,  5,  6,  7,  8,  9,
                 10, 11, 12, 13, 14, 15, 16, 17,
                 18, 19, 20, 21, 22, 23, 24, 25,
                 26, 27, 28, 29, 30, 31, 32, 99);

  // e32: vl=8, rs1=42 ? vd[0..6]=src[1..7]={2..8}, vd[7]=42
  VSET(8, e32, m1);
  VLOAD_32(v16,  1,  2,  3,  4,  5,  6,  7,  8);
  asm volatile("vslide1down.vx v8, v16, %[rs]" :: [rs]"r"((long)42));
  VCMP_U32(2, v8,  2,  3,  4,  5,  6,  7,  8, 42);

#if ELEN == 64
  // e64: vl=4, rs1=77 ? vd[0..2]=src[1..3]={2,3,4}, vd[3]=77
  VSET(4, e64, m1);
  VLOAD_64(v16,  1,  2,  3,  4);
  asm volatile("vslide1down.vx v8, v16, %[rs]" :: [rs]"r"((long)77));
  VCMP_U64(3, v8,  2,  3,  4, 77);
#endif
}

// ?? vmv ???????????????????????????????????????????????????????????????????????

void TEST_vmv(void) {
  // vmv.v.v: copy register
  VSET(8, e32, m1);
  VLOAD_32(v16,  1,  2,  3,  4,  5,  6,  7,  8);
  asm volatile("vmv.v.v v8, v16");
  VCMP_U32(1, v8,  1,  2,  3,  4,  5,  6,  7,  8);

  // vmv.v.i: broadcast immediate
  VSET(8, e32, m1);
  asm volatile("vmv.v.i v8, 7");
  VCMP_U32(2, v8,  7,  7,  7,  7,  7,  7,  7,  7);

  // vmv.v.x: broadcast scalar
  VSET(8, e32, m1);
  asm volatile("vmv.v.x v8, %[rs]" :: [rs]"r"((long)42));
  VCMP_U32(3, v8, 42, 42, 42, 42, 42, 42, 42, 42);

  // vmv.x.s: read element 0 into scalar (non-destructive to vs2)
  VSET(8, e32, m1);
  VLOAD_32(v16, 55,  2,  3,  4,  5,  6,  7,  8);
  long scalar = 0;
  asm volatile("vmv.x.s %[rd], v16" : [rd]"=r"(scalar));
  if ((int)scalar != 55) {
    printf("[TC 4] FAILED. vmv.x.s got %ld, expected 55.\n", scalar);
    num_failed++;
  } else {
    printf("[TC 4] PASSED.\n");
  }

  // vmv.s.x: write scalar into element 0 of vd (elements 1..vl-1 unchanged)
  VSET(8, e32, m1);
  VLOAD_32(v8, 0, 2, 3, 4, 5, 6, 7, 8);
  asm volatile("vmv.s.x v8, %[rs]" :: [rs]"r"((long)99));
  VCMP_U32(5, v8, 99,  2,  3,  4,  5,  6,  7,  8);
}

// ?? vfncvt ????????????????????????????????????????????????????????????????????
// Narrowing FP/int conversions: EW_32 ? EW_16.
// VSET(16, e16) sets vsew_q=e16 (destination SEW); unit_req.vl is halved to 8
// for narrowing, so 8 EW_32 source elements are read (one VRF word).
// VCMP_U16 with 8 expected values ? min(_spatz_vl=8, 8) = 8 elements.

void TEST_vfncvt(void) {
  // vfncvt.f.f.w: FP32 ? FP16
  // Inputs: 1.0 2.0 3.0 -1.0 0.5 4.5 100.0 0.0
  VSET(16, e16, m1);
  VLOAD_32(v16, 0x3f800000, 0x40000000, 0x40400000, 0xbf800000,
                0x3f000000, 0x40900000, 0x42c80000, 0x00000000);
  asm volatile("vfncvt.f.f.w v8, v16");
  VCMP_U16(1, v8, 0x3c00, 0x4000, 0x4200, 0xbc00,
                  0x3800, 0x4480, 0x5640, 0x0000);

  // vfncvt.xu.f.w: FP32 ? u16 (saturate to [0, 65535], RTZ)
  // Inputs: 1.0 2.0 16.0 256.0 1024.0 65535.0 0.0 1000.0
  VSET(16, e16, m1);
  VLOAD_32(v16, 0x3f800000, 0x40000000, 0x41800000, 0x43800000,
                0x44800000, 0x477fff00, 0x00000000, 0x447a0000);
  asm volatile("vfncvt.xu.f.w v8, v16");
  VCMP_U16(2, v8, 1, 2, 16, 256, 1024, 65535, 0, 1000);

  // vfncvt.x.f.w: FP32 ? i16 (saturate to [-32768, 32767], RTZ)
  // Inputs: 1.0 -1.0 100.0 -100.0 1000.0 -1000.0 32767.0 -32768.0
  VSET(16, e16, m1);
  VLOAD_32(v16, 0x3f800000, 0xbf800000, 0x42c80000, 0xc2c80000,
                0x447a0000, 0xc47a0000, 0x46fffe00, 0xc7000000);
  asm volatile("vfncvt.x.f.w v8, v16");
  VCMP_U16(3, v8, 1, (uint16_t)-1, 100, (uint16_t)-100,
                  1000, (uint16_t)-1000, 32767, (uint16_t)-32768);
}

int main(void) {
  INIT_CHECK();
  enable_vec();
  enable_fp();

  TEST_vredsum();
  TEST_vredand();
  TEST_vredor();
  TEST_vredxor();
  TEST_vredmin();
  TEST_vredminu();
  TEST_vredmax();
  TEST_vredmaxu();
  TEST_vfredmin();
  TEST_vfredmax();
  TEST_vfredosum();
  TEST_vfredusum();
  TEST_vslideup();
  TEST_vslidedown();
  TEST_vslide1up();
  TEST_vslide1down();
  TEST_vmv();
  TEST_vfncvt();

  EXIT_CHECK();
}
