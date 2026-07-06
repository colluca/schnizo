#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments.SimResults import SimRegion
from snitch.util.experiments import experiment_utils as eu
from snitch.util.experiments.common import MK_DIR
from pathlib import Path

# TODO(colluca): which kernels partition the data across cores, and which don't?

HARDWARE_ALIASES = {
    'S': '1x1_1x1_1x1',
    'M': '1x4_1x4_1x4',
    'GP-M': '1x128_1x32_1x64',
    'GP-L': '3x32_3x32_1x64',
    'LA': '3x4_3x4_1x4',
    'MC': '3x32_1x0_2x32',
    'TR': '2x32_1x32_2x32',
}

APPLICATION_CLASS = {
    'LA': ['sz_axpy', 'sz_dot'],
    'MC': ['pi_lcg', 'pi_xoshiro128p', 'poly_lcg', 'poly_xoshiro128p'],
    'TR': ['log', 'exp'],
}
APPLICATION_CLASS['GP'] = [app for classes in APPLICATION_CLASS.values() for app in classes]

# Maps hw string to its target app class; absent keys accept all apps (GP)
_HW_APP_CLASS = {HARDWARE_ALIASES[cls]: cls for cls in ['LA', 'MC', 'TR']}

DNN_SIMPLE_APPS = ['relu', 'gelu', 'silu', 'layernorm', 'rms_norm', 'batchnorm', 'softmax']
DNN_ELTWISE_OPS = ['ELTWISE_ADD', 'ELTWISE_MUL', 'ELTWISE_NEG', 'ELTWISE_DIV']
DNN_APPS = DNN_SIMPLE_APPS + ['eltwise']

class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        base_axes = eu.derive_axes_from_keys(experiment, keys=['app', 'mode', 'hw'])
        if experiment['app'] == 'pi_estimation':
            base_axes['app'] = f"{experiment['mc_app']}_{experiment['mc_prng']}"
        if experiment['app'] == 'eltwise':
            base_axes['app'] = experiment['op'].replace('ELTWISE_', '').lower()
        if experiment['app'] in ['sz_axpy', 'sz_dot', 'pi_estimation']:
            return {**base_axes, 'size': experiment['data_cfg']['n']}
        if experiment['app'] in ['exp', 'log']:
            return {**base_axes, 'size': experiment['data_cfg']['len']}
        if experiment['app'] in DNN_APPS:
            return {**base_axes, 'size': experiment['data_cfg']['size']}
        return base_axes

    def derive_hw_cfg(self, experiment):
        return Path.cwd() / f"cfg/{experiment['hw']}.json"

    def derive_data_cfg(self, experiment):
        if experiment['app'] not in ['pi_estimation']:
            template_path = Path(f"data/{experiment['app']}_cfg.json.tpl")
            return eu.derive_data_cfg_from_template(experiment, template_path=template_path)

    def derive_cdefines(self, experiment):
        cdefines = {}
        if experiment['mode'] == 'scalar':
            cdefines['FORCE_HW_LOOP'] = 1
        if experiment['app'] == 'pi_estimation':
            cdefines['N_SAMPLES'] = experiment['data_cfg']['n']
            cdefines['APPLICATION'] = 'APPLICATION_' + experiment['mc_app'].upper()
            cdefines['PRNG'] = 'PRNG_' + experiment['mc_prng'].upper()
            cdefines['FUNC_PTR'] = experiment['data_cfg']['func_ptr']
        if experiment['app'] == 'exp' or experiment['app'] == 'log':
            cdefines['FUNC_PTR'] = experiment['data_cfg']['func_ptr']
        if (experiment['app'] == 'eltwise'   or 
            experiment['app'] == 'batchnorm' or
            experiment['app'] == 'gelu'      or
            experiment['app'] == 'relu'      or
            experiment['app'] == 'silu'      or
            experiment['app'] == 'softmax'):
            cdefines['FORCE_THREE_LSU_OPS'] = 1
        return cdefines

    def derive_env(self, experiment):
        env = super().derive_env(experiment)
        if experiment['app'] in DNN_APPS:
            env['SN_HW_FDIV'] = '1'
        return env

def gen_experiments():
    # Define experiment axes
    cfgs = [
        #'3x32_3x32_1x64',
        'GP-PW8',
    ]

    modes = [
             'superscalar'
             ]
    sizes = [4096]
    app_filter = None
    core = None

    # Generate experiment list
    experiments = []
    for cfg in cfgs:
        # Check if this config targets the schnova core
        is_schnova_core = cfg.startswith('sv') or cfg.startswith('schnova') or cfg.startswith('GP')
        has_zol = cfg.endswith('zol') or cfg.startswith('GP') or cfg.startswith('3x32')
        core = 'schnova' if is_schnova_core else None
        app_class = _HW_APP_CLASS.get(cfg)
        compatible = set(APPLICATION_CLASS[app_class] if app_class else APPLICATION_CLASS['GP'])
        for mode in modes:
            for size in sizes:
                sim_bin = str(Path.cwd() / 'hw' / cfg / 'bin/snitch_cluster.vsim')
                if compatible & set(APPLICATION_CLASS['LA']):
                    experiments.extend([
                        {
                            'app': 'sz_dot',
                            'hw': cfg,
                            'mode': mode,
                            'core': core,
                            'data_cfg': {
                                'n': size,
                                'funcptr': 'dot_baseline' if not has_zol else 'dot_schnizo',
                            },
                            'cmd': [str(MK_DIR / 'sw/kernels/blas/sz_dot/scripts/verify.py'),
                                    sim_bin, "${elf}"],
                            'roi': Path("roi/sz_dot_roi.json.tpl")
                        },
                        {
                            'app': 'sz_axpy',
                            'hw': cfg,
                            'mode': mode,
                            'core': core,
                            'data_cfg': {
                                'n': size,
                                'funcptr':
                                'axpy_fma' if not has_zol else
                                'axpy_baseline' if mode == 'scalar' else 
                                'axpy_schnova',
                            },
                            'cmd': [str(MK_DIR / 'sw/kernels/blas/sz_axpy/scripts/verify.py'),
                                    sim_bin, "${elf}"],
                            'roi': Path("roi/sz_axpy_roi.json.tpl")
                        },
                    ])
                if compatible & set(APPLICATION_CLASS['TR']):
                    experiments.extend([
                        {
                            'app': 'exp',
                            'hw': cfg,
                            'mode': mode,
                            'core': core,
                            'data_cfg': {
                                'len': size,
                                'batch_size': size,
                                'func_ptr': 'vexpf_baseline' if not has_zol else 'vexpf_schnizo'
                            },
                            'cmd': [str(MK_DIR / 'sw/kernels/misc/exp/scripts/verify.py'),
                                    sim_bin, "${elf}"],
                            'roi': Path("roi/exp.json.tpl")
                        },
                        {
                            'app': 'log',
                            'hw': cfg,
                            'mode': mode,
                            'core': core,
                            'data_cfg': {
                                'len': size,
                                'batch_size': size,
                                'func_ptr': 'vlogf_baseline' if not has_zol else 'vlogf_schnizo'
                            },
                            'cmd': [str(MK_DIR / 'sw/kernels/misc/log/scripts/verify.py'),
                                    sim_bin, "${elf}"],
                            'roi': Path("roi/log.json.tpl")
                        },
                    ])
                if compatible & set(APPLICATION_CLASS['MC']):
                    for mc_app in ['pi', 'poly']:
                        for mc_prng in ['lcg', 'xoshiro128p']:
                            experiments.append({
                                # TODO(colluca): rename app montecarlo
                                'app': 'pi_estimation',
                                'hw': cfg,
                                'mc_app': mc_app,
                                'mc_prng': mc_prng,
                                'mode': mode,
                                'core': core,
                                'data_cfg': {
                                    'n': size,
                                    'func_ptr': 'calculate_psum_baseline' if not has_zol else 'calculate_psum_schnizo',  # noqa: E501
                                },
                                'cmd': [str(MK_DIR / 'sw/kernels/misc/montecarlo/pi_estimation/scripts/verify.py'),  # noqa: E501
                                        sim_bin, "${elf}"],
                                'roi': Path("roi/pi_estimation.json.tpl")
                            })

                if has_zol or not is_schnova_core:
                    for app in DNN_SIMPLE_APPS:
                        verify = MK_DIR / f"sw/kernels/dnn/{app}/scripts/verify.py"
                        cmd = [str(verify), sim_bin, "${elf}"] if verify.exists() else [sim_bin, "${elf}"]
                        experiments.append({
                            'app': app,
                            'hw': cfg,
                            'mode': mode,
                            'core': core,
                            'data_cfg': {'size': size},
                            'cmd': cmd,
                            'roi': Path("roi/dnn.json.tpl"),
                        })
                    for op in DNN_ELTWISE_OPS:
                        verify = MK_DIR / "sw/kernels/dnn/eltwise/scripts/verify.py"
                        experiments.append({
                            'app': 'eltwise',
                            'op': op,
                            'hw': cfg,
                            'mode': mode,
                            'core': core,
                            'data_cfg': {'size': size, 'op': op},
                            'cmd': [str(verify), sim_bin, "${elf}"],
                            'roi': Path("roi/dnn.json.tpl"),
                        })

    # Filter by apps
    if app_filter is not None:
        experiments = [e for e in experiments
                       if e['app'] in app_filter
                       or f"{e.get('mc_app')}_{e.get('mc_prng')}" in app_filter]

    return experiments


def results(dir=None):
    df = ExperimentManager(gen_experiments(), dir=dir, parse_args=False).get_results()
    roi = SimRegion('hart_0', 'compute')
    #df['total_power'] = df.apply(lambda row: row['power_results'].total_power, axis=1)
    #df['clock_power'] = df.apply(lambda row: row['power_results'].clock_power, axis=1)
    #print(df['total_power'])
    #print(df['clock_power'])
    df['ipc'] = df.apply(lambda row: row['results'].get_metric(roi, 'ipc'), axis=1)
    df['fpu_util'] = df.apply(lambda row: row['results'].get_metric(roi, 'fpu_util'), axis=1)
    return df


def main():
    parser = ExperimentManager.parser()
    args = parser.parse_args()
    experiments = gen_experiments()
    manager = ExperimentManager(experiments=experiments, args=args, parse_args=False)

    manager.run()


if __name__ == '__main__':
    main()
