#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import json
import json5
import pandas as pd
from pathlib import Path

from . import registry as reg
from snitch.util.experiments import experiment_utils as eu
from snitch.util.experiments.common import MK_DIR
from snitch.util.experiments.SimResults import SimRegion

DATA_DIR = Path(__file__).parent / 'data'

HW = '3x32_3x32_1x64'

VARIANTS = ['zol', 'superscalar']
# VARIANTS = ['naive', 'baseline', 'zol', 'superscalar']

# Maps variant name to the C kernel function suffix (funcptr name).
KERNEL = {
    'naive':       'naive',
    'baseline':    'baseline',
    'zol':         'schnizo',
    'superscalar': 'schnizo',
}

# ELTWISE_OPS = ['ELTWISE_ADD']
ELTWISE_OPS = ['ELTWISE_ADD', 'ELTWISE_MUL', 'ELTWISE_DIV', 'ELTWISE_NEG']

# APPS = ['gelu']
APPS = ['eltwise', 'relu', 'layernorm', 'batchnorm', 'rms_norm', 'softmax', 'silu', 'gelu']


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        app = experiment['op'].lower() if experiment['app'] == 'eltwise' else experiment['app']
        axes = {'app': app, 'hw': experiment['hw'], 'variant': experiment['variant']}
        size_cfg = experiment.get('size_cfg', {})
        if not size_cfg:
            return axes
        kernel = experiment['app']
        if kernel in ('relu', 'gelu', 'silu', 'eltwise'):
            axes['size'] = size_cfg['size']
        elif kernel == 'layernorm':
            axes['embeddings'] = size_cfg['input_dim']['embeddings']
        elif kernel == 'rms_norm':
            axes['hidden_dim'] = size_cfg['input_dim']['hidden_dim']
        elif kernel == 'softmax':
            axes['input_samples'] = size_cfg['input_dim']['input_samples']
        elif kernel == 'batchnorm':
            axes['IH'] = size_cfg['IH']
            axes['IW'] = size_cfg['IW']
        return axes

    def derive_hw_cfg(self, experiment):
        return Path(__file__).parent / f"cfg/{experiment['hw']}.json"

    def derive_data_cfg(self, experiment):
        app = experiment['app']
        default_cfg = MK_DIR / f"sw/kernels/dnn/{app}/data/params.json"
        with open(default_cfg) as f:
            default_params = json5.loads(f.read())
        prefix = '_'.join(default_params['funcptr'].split('_')[:-1])
        overrides = {'funcptr': f"{prefix}_{experiment['kernel']}"}
        if app == 'eltwise':
            overrides['op'] = experiment['op']
        overrides.update(experiment.get('size_cfg', {}))
        return eu.derive_data_cfg_from_overrides(
            experiment, default_cfg, overrides, root_cfg_dir=DATA_DIR)

    def derive_cdefines(self, experiment):
        if experiment['variant'] == 'zol':
            return {'FORCE_HW_LOOP': 1}
        return {}

    def derive_env(self, experiment):
        env = super().derive_env(experiment)
        env['SN_HW_FDIV'] = '1'
        return env


def _size_cfg(app, clamped):
    if app in ('relu', 'gelu', 'silu', 'eltwise'):
        return {'size': clamped['size']}
    if app in ('layernorm', 'rms_norm'):
        return {'input_dim': clamped['input_dim']}
    if app == 'softmax':
        return {'input_dim': clamped['input_dim'], 'reduce_dim': clamped['reduce_dim']}
    if app == 'batchnorm':
        return {'CI': clamped['CI'], 'IH': clamped['IH'], 'IW': clamped['IW']}
    return {}


def gen_experiments_debug():
    sim_bin = str(Path.cwd() / f"hw/{HW}/bin/snitch_cluster.vsim")
    experiments = []

    for variant in VARIANTS:
        for app in APPS:
            if app == 'eltwise':
                for op in ELTWISE_OPS:
                    experiments.append({
                        'app': app,
                        'hw': HW,
                        'variant': variant,
                        'kernel': KERNEL[variant],
                        'op': op,
                        'cmd': [str(MK_DIR / f"sw/kernels/dnn/{app}/scripts/verify.py"),
                                sim_bin, "${elf}"],
                    })
            else:
                verify = MK_DIR / f"sw/kernels/dnn/{app}/scripts/verify.py"
                cmd = [str(verify), sim_bin, "${elf}"] if verify.exists() else [sim_bin, "${elf}"]
                experiments.append({
                    'app': app,
                    'hw': HW,
                    'variant': variant,
                    'kernel': KERNEL[variant],
                    'cmd': cmd,
                })

    return experiments


def gen_experiments_registry():
    sim_bin = str(Path.cwd() / f"hw/{HW}/bin/snitch_cluster.vsim")
    df = pd.read_csv(reg.csv)
    # eltwise op name → registry kernel name
    eltwise_kernel = {op: op.replace('ELTWISE_', '').lower() for op in ELTWISE_OPS}
    experiments = []

    for variant in VARIANTS:
        for app in APPS:
            if app == 'eltwise':
                for op in ELTWISE_OPS:
                    kernel = eltwise_kernel[op]
                    seen = set()
                    op_names = reg.KERNEL_TO_OPS[kernel]
                    for shape_str in df.loc[df['op_name'].isin(op_names), 'shape']:
                        params = reg.shape_to_params(shape_str, kernel)
                        if params is None:
                            continue
                        clamped, _ = reg.clamp_params(params, kernel)
                        key = json.dumps(clamped, sort_keys=True)
                        if key in seen:
                            continue
                        seen.add(key)
                        experiments.append({
                            'app': app,
                            'hw': HW,
                            'variant': variant,
                            'kernel': KERNEL[variant],
                            'op': op,
                            'size_cfg': _size_cfg(app, clamped),
                            'cmd': [str(MK_DIR / f"sw/kernels/dnn/{app}/scripts/verify.py"),
                                    sim_bin, "${elf}"],
                        })
            else:
                seen = set()
                op_names = reg.KERNEL_TO_OPS[app]
                for shape_str in df.loc[df['op_name'].isin(op_names), 'shape']:
                    params = reg.shape_to_params(shape_str, app)
                    if params is None:
                        continue
                    clamped, _ = reg.clamp_params(params, app)
                    key = json.dumps(clamped, sort_keys=True)
                    if key in seen:
                        continue
                    seen.add(key)
                    verify = MK_DIR / f"sw/kernels/dnn/{app}/scripts/verify.py"
                    cmd = [str(verify), sim_bin, "${elf}"] if verify.exists() else [sim_bin, "${elf}"]
                    experiments.append({
                        'app': app,
                        'hw': HW,
                        'variant': variant,
                        'kernel': KERNEL[variant],
                        'size_cfg': _size_cfg(app, clamped),
                        'cmd': cmd,
                    })

    return experiments


def gen_experiments(mode='debug'):
    if mode == 'debug':
        return gen_experiments_debug()
    elif mode == 'registry':
        return gen_experiments_registry()
    else:
        raise ValueError(f"Unknown mode: {mode!r}")


def results(dir=None, mode='debug'):
    if dir is None:
        dir = Path(__file__).parent
    df = ExperimentManager(gen_experiments(mode), dir=dir, parse_args=False).get_results()
    roi = SimRegion('hart_0', 'compute')
    df['ipc']    = df.apply(lambda row: row['results'].get_metric(roi, 'ipc'),    axis=1)
    df['tstart'] = df.apply(lambda row: row['results'].get_metric(roi, 'tstart'), axis=1)
    df['tend']   = df.apply(lambda row: row['results'].get_metric(roi, 'tend'),   axis=1)
    return df


def main():
    parser = ExperimentManager.parser()
    parser.add_argument('--mode', choices=['debug', 'registry'], default='debug',
                        help='debug: fixed default sizes; registry: sizes from registry shapes')
    args = parser.parse_args()
    manager = ExperimentManager(experiments=gen_experiments(args.mode), args=args, parse_args=False)
    manager.run()


if __name__ == '__main__':
    main()
