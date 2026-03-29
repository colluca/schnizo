#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import pandas as pd

SCHNIZO_XL = {
    'alu': 3,
    'lsu': 3,
    'fpu': 1
}
SCHNIZO_LA = SCHNIZO_XL
SCHNIZO_MC = {
    'alu': 2,
    'lsu': 1,
    'fpu': 2
}
SCHNIZO_CFGS = [
    SCHNIZO_LA, SCHNIZO_MC
]

BENCHMARK_INSNS = {
    'superscalar': {
        'sz_axpy':          {'alu':  3, 'fpu':  1, 'lsu':  3},
        'sz_dot':           {'alu':  2, 'fpu':  4, 'lsu':  8},
        'exp':              {'alu': 22, 'fpu': 40, 'lsu': 28},
        'log':              {'alu': 34, 'fpu': 40, 'lsu': 16},
        'pi_lcg':           {'alu': 20, 'fpu': 28, 'lsu':  0},
        'pi_xoshiro128p':   {'alu': 84, 'fpu': 28, 'lsu':  0},
        'poly_lcg':         {'alu': 20, 'fpu': 40, 'lsu':  0},
        'poly_xoshiro128p': {'alu': 84, 'fpu': 40, 'lsu':  0},
    }
}
BENCHMARK_INSNS['scalar'] = BENCHMARK_INSNS['superscalar'].copy()
BENCHMARK_INSNS['scalar']['sz_axpy'] = {'alu':  3, 'fpu':  4, 'lsu':  12}


def ideal_ipc(insns, cfg):
    """Compute ideal IPC based on instruction mix and FU counts (bottleneck analysis)."""
    total = sum(insns.values())
    cycles = max(insns[fu] / cfg[fu] for fu in cfg if insns.get(fu, 0))
    return total / cycles


def ideal_fpu_util(insns):
    return insns['fpu'] / sum(insns.values())


def theoretical_metrics(cfg=None):
    d = {
        'fpu_util': {
            'scalar': {
                app: ideal_fpu_util(BENCHMARK_INSNS['scalar'][app])
                for app in ['sz_axpy', 'sz_dot']
            }
        }
    }
    if cfg is not None:
        d['ipc'] = {
                'superscalar': {
                    app: ideal_ipc(BENCHMARK_INSNS['superscalar'][app], cfg)
                    for app in BENCHMARK_INSNS['superscalar']
                }
            }
    return d


def main():
    df = pd.DataFrame(
        {
            cfg: theoretical_metrics(cfg)['ipc']['superscalar']
            for cfg in SCHNIZO_CFGS
        }
    )
    print(df)
    

if __name__ == '__main__':
    main()
