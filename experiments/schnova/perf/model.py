#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import pandas as pd
import math

SCHNOVA_S = {
    'alu': 1,
    'lsu': 1,
    'fpu': 1
}

SCHNOVA_M = {
    'alu': 2,
    'lsu': 2,
    'fpu': 1
}

SCHNOVA_XL = {
    'alu': 3,
    'lsu': 3,
    'fpu': 1
}

# Each entry contains:
#
#   name
#   functional-unit configuration
#   front-end pipeline width
#   FPU-division occupancy / initiation interval
#
# fdiv_ii is the number of cycles for which one non-pipelined division
# occupies an FPU.
SCHNIZO_CFGS = [
    ('Schnova-S', SCHNOVA_S, 1, 14),
    ('Schnova-M', SCHNOVA_M, 2, 14),
]

# Instruction counts

# fpu: Ordinary pipelined FPU instructions, assumed to have an initiation interval 1.
# fdiv: Non-pipelined floating-point division instructions.
# Total instructions: alu + lsu + fpu + fdiv


BENCHMARK_INSNS = {
    'superscalar': {
        'sz_axpy': { 'alu': 3, 'fpu': 1, 'fdiv': 0, 'lsu': 3 },
        'sz_dot': { 'alu': 2, 'fpu': 4, 'fdiv': 0, 'lsu': 8, },
        'exp': { 'alu': 22, 'fpu': 40, 'fdiv': 0, 'lsu': 28, },
        'log': { 'alu': 34, 'fpu': 40, 'fdiv': 0, 'lsu': 16, },
        'pi_lcg': { 'alu': 20, 'fpu': 28, 'fdiv': 0, 'lsu': 0, },
        'pi_xoshiro128p': { 'alu': 84, 'fpu': 28, 'fdiv': 0, 'lsu': 0,},
        'poly_lcg': { 'alu': 20, 'fpu': 40, 'fdiv': 0, 'lsu': 0, },
        'poly_xoshiro128p': { 'alu': 84, 'fpu': 40, 'fdiv': 0, 'lsu': 0,},
        # DNN kernels - simple load-use-store, counts per frep.o iteration (1 element).
        'relu': { 'alu': 2, 'fpu': 1, 'fdiv': 0, 'lsu': 2, },
        'batchnorm': { 'alu': 2, 'fpu': 1, 'fdiv': 0, 'lsu': 2, },
        'add': { 'alu': 3, 'fpu': 1, 'fdiv': 0, 'lsu': 3, },
        'mul': { 'alu': 3, 'fpu': 1, 'fdiv': 0, 'lsu': 3, },
        'neg': { 'alu': 2, 'fpu': 1, 'fdiv': 0, 'lsu': 2 },
        'div': { 'alu': 3,'fpu': 0,'fdiv': 1,'lsu': 3 },
        # DNN kernels - composite/multi-pass, counts per 4 elements.
        # gelu/silu: neg/fmul-step + vexpf_fp32 + fadd-step + fdiv-step.
        # vexpf_fp32 body: alu=22, fpu=48 (+8 fcvt vs double vexpf), lsu=28 per 4 elems.
        'gelu': {'alu': 27, 'fpu': 51, 'fdiv': 1, 'lsu': 35 },
        'silu': { 'alu': 27, 'fpu': 51, 'fdiv': 1, 'lsu': 35 },
        'softmax': { 'alu': 40, 'fpu': 64, 'fdiv': 0, 'lsu': 52 },
        'layernorm': { 'alu': 6, 'fpu': 40, 'fdiv': 0, 'lsu': 32 },
        'rms_norm': { 'alu': 5, 'fpu': 24, 'fdiv': 0, 'lsu': 32 },
    }
}


BENCHMARK_INSNS['scalar'] = {
    app: counts.copy()
    for app, counts in BENCHMARK_INSNS['superscalar'].items()
}

BENCHMARK_INSNS['scalar']['sz_axpy'] = { 'alu': 3, 'fpu': 4, 'fdiv': 0, 'lsu': 12 }
# Simple DNN kernels: frep.i and pw1, pw2 uses 4x-unrolled bodies.
BENCHMARK_INSNS['scalar']['relu'] = { 'alu': 2, 'fpu': 4, 'fdiv': 0, 'lsu': 8 }
BENCHMARK_INSNS['scalar']['batchnorm'] = { 'alu': 2, 'fpu': 4, 'fdiv': 0, 'lsu': 8 }
BENCHMARK_INSNS['scalar']['add'] = { 'alu': 3, 'fpu': 4, 'fdiv': 0, 'lsu': 12 }
BENCHMARK_INSNS['scalar']['mul'] = { 'alu': 3, 'fpu': 4, 'fdiv': 0, 'lsu': 12 }
BENCHMARK_INSNS['scalar']['neg'] = { 'alu': 2, 'fpu': 4, 'fdiv': 0, 'lsu': 8 }
# Composite DNN kernels.
BENCHMARK_INSNS['scalar']['softmax'] = { 'alu': 34, 'fpu': 64, 'fdiv': 0, 'lsu': 52 }

def validate_instruction_counts(insns):
    required_classes = {'alu', 'lsu', 'fpu', 'fdiv'}
    missing_classes = required_classes - set(insns)

    if missing_classes:
        raise ValueError(
            f'Missing instruction classes: {sorted(missing_classes)}'
        )

    for insn_class, count in insns.items():
        if count < 0:
            raise ValueError(
                f'Instruction count for {insn_class} must be non-negative'
            )


def total_instruction_count(insns):
    """
    Total number of architectural instructions.

    fdiv is counted separately from fpu but remains part of the total
    instruction count.
    """
    validate_instruction_counts(insns)

    return (
        insns['alu']
        + insns['lsu']
        + insns['fpu']
        + insns['fdiv']
    )


def alu_cycles(insns, cfg):
    return math.ceil(insns['alu'] / cfg['alu'])


def lsu_cycles(insns, cfg):
    return math.ceil(insns['lsu'] / cfg['lsu'])


def fpu_cycles(insns, cfg, fdiv_ii):
    """
    Compute cycles imposed by the FPU resources.

    Ordinary FPU instructions have occupancy 1 cycle.

    Every non-pipelined fdiv occupies an FPU for fdiv_ii cycles. Therefore,
    total FPU service demand is:

        fpu + fdiv_ii * fdiv

    This demand is distributed over cfg['fpu'] FPUs.
    """
    fpu_service_cycles = (
        insns['fpu']
        + fdiv_ii * insns['fdiv']
    )

    return math.ceil(fpu_service_cycles / cfg['fpu'])


def dispatch_cycles(insns, pipe_width):
    if pipe_width is None:
        return 0

    return math.ceil(
        total_instruction_count(insns) / pipe_width
    )


def ideal_cycles(insns, cfg, pipe_width=None, fdiv_ii=12):
    """
    Compute ideal execution cycles assuming:

      - no instruction dependencies,
      - perfect scheduling,
      - no cache misses,
      - no branch penalties,
      - ordinary ALU, LSU, and FPU instructions are fully pipelined,
      - fdiv instructions occupy an FPU for fdiv_ii cycles.
    """
    validate_instruction_counts(insns)

    return max(
        alu_cycles(insns, cfg),
        lsu_cycles(insns, cfg),
        fpu_cycles(insns, cfg, fdiv_ii),
        dispatch_cycles(insns, pipe_width),
    )


def ideal_ipc(insns, cfg, pipe_width=None, fdiv_ii=12):
    cycles = ideal_cycles(
        insns=insns,
        cfg=cfg,
        pipe_width=pipe_width,
        fdiv_ii=fdiv_ii,
    )

    if cycles == 0:
        return 0.0

    return total_instruction_count(insns) / cycles


def ideal_fpu_util(insns):
    """
    Fraction of architectural instructions that use an FPU.

    fdiv instructions are included because they are FPU instructions.
    """
    total_insns = total_instruction_count(insns)

    if total_insns == 0:
        return 0.0

    return (
        insns['fpu'] + insns['fdiv']
    ) / total_insns


def theoretical_metrics(cfg=None, pipe_width=None, fdiv_ii=12):
    """
    Calculate theoretical metrics for both scalar and superscalar
    instruction count models.

    The scalar instruction counts represent kernels whose loop bodies are
    unrolled in software. The superscalar instruction counts represent
    kernels that use the superscalar execution structure.
    """
    metrics = {
        'fpu_util': {
            mode: {
                app: ideal_fpu_util(insns)
                for app, insns in benchmark_insns.items()
            }
            for mode, benchmark_insns in BENCHMARK_INSNS.items()
        }
    }

    if cfg is not None:
        metrics['ipc'] = {
            mode: {
                app: ideal_ipc(
                    insns=insns,
                    cfg=cfg,
                    pipe_width=pipe_width,
                    fdiv_ii=fdiv_ii,
                )
                for app, insns in benchmark_insns.items()
            }
            for mode, benchmark_insns in BENCHMARK_INSNS.items()
        }

    return metrics


# ---------------------------------------------------------------------------
# Table generation
# ---------------------------------------------------------------------------

def main():
    rows = {}

    for app, insns in BENCHMARK_INSNS['superscalar'].items():
        row = {}

        for cfg_name, cfg, pipe_width, fdiv_ii in SCHNIZO_CFGS:
            row[(cfg_name, 'alu_cycles')] = alu_cycles(insns, cfg)
            row[(cfg_name, 'lsu_cycles')] = lsu_cycles(insns, cfg)
            row[(cfg_name, 'fpu_cycles')] = fpu_cycles(
                insns,
                cfg,
                fdiv_ii,
            )
            row[(cfg_name, 'dispatch_cycles')] = dispatch_cycles(
                insns,
                pipe_width,
            )
            row[(cfg_name, 'ideal_cycles')] = ideal_cycles(
                insns=insns,
                cfg=cfg,
                pipe_width=pipe_width,
                fdiv_ii=fdiv_ii,
            )
            row[(cfg_name, 'ipc')] = ideal_ipc(
                insns=insns,
                cfg=cfg,
                pipe_width=pipe_width,
                fdiv_ii=fdiv_ii,
            )

        rows[app] = row

    df = pd.DataFrame.from_dict(rows, orient='index')

    df.columns = pd.MultiIndex.from_tuples(
        df.columns,
        names=['config', 'metric'],
    )

    metric_order = [
        'alu_cycles',
        'lsu_cycles',
        'fpu_cycles',
        'dispatch_cycles',
        'ideal_cycles',
        'ipc',
    ]

    config_order = [
        cfg_name
        for cfg_name, _, _, _ in SCHNIZO_CFGS
    ]

    df = df.reindex(
        columns=pd.MultiIndex.from_product(
            [config_order, metric_order],
            names=['config', 'metric'],
        )
    )

    print(df.to_string())


if __name__ == '__main__':
    main()
