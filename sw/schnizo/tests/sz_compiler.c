// This simple Snitch program encounters a compiler problem if tmp is not marked as volatile.
//
// In the asm block the %[tmp] and %[n_frep] values are assigned to the same register.
// The "mv" instruction then overwrites the value and thus the argument for the "frep.o"
// instruction is wrong.
// The program works as expected if the %[tmp] is replaced by a explicit register (and this register
// is also added to the clobbers list).

// Toolchain used is installed on pisoc here:
// /usr/scratch2/vulcano/colluca/tools/riscv32-snitch-llvm-almalinux8-15.0.0-snitch-0.1.0/bin
// Contact Pascal Etterli or Luca Colagrande for more details.

#include "snrt.h"

#define NofElements 16

double x[NofElements] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};

double sum_exp = 136; // the sum of all integers from 1 to 16

int main() {
    if (!snrt_is_compute_core()) {
        return 0;
    }

    const uint32_t n_reps = NofElements;
    register volatile double res asm("ft1") = 0;
    double* addr = &x[0] - 1; // switch addi and fld -> subtract one element

    // for fence, must be volatile because it is unused and therefore the compiler will allocate
    // the same register for [tmp] and [addr].
    unsigned volatile tmp;
    asm volatile(
        // Wait until all FPU & LSU instructions have retired to have a clean register and
        // pipeline state. Note, the cache is not yet synchronized.
        // We must place it in the same asm block as otherwise instructions are placed in between.
        "fmv.x.w %[tmp], fa0   \n"
        "mv      %[tmp], %[tmp]\n"
        "fence\n"
        // loop
        "frep.o %[n_frep], 3,         0, 0\n"
        "addi   %[addr],   %[addr],   8   \n" // switch order of addi and fld to prevent deadlock
        "fld    ft0,       0(%[addr])     \n"
        "fadd.d %[res],    %[res],    ft0"
        // outputs
        : [res]"+r"(res), [addr]"+r"(addr), [tmp]"+r"(tmp)
        // inputs - FREP repeats n_frep+1 times..
        : [n_frep]"r"(n_reps-1)
        // clobbers - modified registers beyond the outputs
        : "ft0"
    );

    if ((res - sum_exp) > 0.001) {
        return 1;
    }
    return 0;
}