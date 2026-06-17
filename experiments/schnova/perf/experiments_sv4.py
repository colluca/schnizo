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


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        base_axes = eu.derive_axes_from_keys(experiment, keys=['app', 'mode', 'hw'])
        if experiment['app'] == 'pi_estimation':
            base_axes['app'] = f"{experiment['mc_app']}_{experiment['mc_prng']}"
        if experiment['app'] in ['sz_axpy', 'sz_dot', 'pi_estimation']:
            return {**base_axes, 'size': experiment['data_cfg']['n']}
        if experiment['app'] in ['exp', 'log']:
            return {**base_axes, 'size': experiment['data_cfg']['len']}
        return base_axes

    def derive_hw_cfg(self, experiment):
        return Path.cwd() / f"cfg_sv4/{experiment['hw']}.json"

    def derive_data_cfg(self, experiment):
        if experiment['app'] not in ['pi_estimation']:
            template_path = Path(f"data/{experiment['app']}_cfg.json.tpl")
            return eu.derive_data_cfg_from_template(experiment, template_path=template_path)

    def derive_cdefines(self, experiment):
        cdefines = {}
        if experiment['mode'] == 'scalar':
            cdefines['FORCE_HW_LOOP'] = 1
        if experiment['app'] == 'exp' or experiment['app'] == 'log':
            cdefines['FUNC_PTR'] = experiment['data_cfg']['func_ptr']
        if experiment['app'] == 'pi_estimation':
            cdefines['N_SAMPLES'] = experiment['data_cfg']['n']
            cdefines['APPLICATION'] = 'APPLICATION_' + experiment['mc_app'].upper()
            cdefines['PRNG'] = 'PRNG_' + experiment['mc_prng'].upper()
            cdefines['FUNC_PTR'] = experiment['data_cfg']['func_ptr']
        return cdefines


def gen_experiments(ci=False):
    # Define experiment axes
    cfgs_alu_slots = [
            'sv_4_3x1_3x32_1x32_128_128_128_128_128_0',
            'sv_4_3x2_3x32_1x32_128_128_128_128_128_0',
            'sv_4_3x3_3x32_1x32_128_128_128_128_128_0',
            'sv_4_3x4_3x32_1x32_128_128_128_128_128_0',
            'sv_4_3x5_3x32_1x32_128_128_128_128_128_0',
    ]

    cfgs_lsu_slots = [
            'sv_4_3x1_3x1_1x32_128_128_128_128_128_0',
            'sv_4_3x1_3x2_1x32_128_128_128_128_128_0',
            'sv_4_3x1_3x3_1x32_128_128_128_128_128_0',
            'sv_4_3x1_3x4_1x32_128_128_128_128_128_0',
            'sv_4_3x1_3x5_1x32_128_128_128_128_128_0',
    ]

    cfgs_fpu_slots = [
            'sv_4_3x1_3x4_1x1_128_128_128_128_128_0',
            'sv_4_3x1_3x4_1x2_128_128_128_128_128_0',
            'sv_4_3x1_3x4_1x3_128_128_128_128_128_0',
            'sv_4_3x1_3x4_1x4_128_128_128_128_128_0',
            'sv_4_3x1_3x4_1x5_128_128_128_128_128_0',
    ]

    cfgs_alu_buf_slots = [
            'sv_4_3x1_3x4_1x1_4_128_128_128_128_0',
            'sv_4_3x1_3x4_1x1_6_128_128_128_128_0',
            'sv_4_3x1_3x4_1x1_8_128_128_128_128_0',
            'sv_4_3x1_3x4_1x1_10_128_128_128_128_0',
            'sv_4_3x1_3x4_1x1_12_128_128_128_128_0',
            'sv_4_3x1_3x4_1x1_14_128_128_128_128_0',
            'sv_4_3x1_3x4_1x1_16_128_128_128_128_0',
            'sv_4_3x1_3x4_1x1_18_128_128_128_128_0',
            'sv_4_3x1_3x4_1x1_20_128_128_128_128_0',
            'sv_4_3x1_3x4_1x1_22_128_128_128_128_0',
            'sv_4_3x1_3x4_1x1_24_128_128_128_128_0',
            'sv_4_3x1_3x4_1x1_26_128_128_128_128_0',
            'sv_4_3x1_3x4_1x1_28_128_128_128_128_0',
            'sv_4_3x1_3x4_1x1_30_128_128_128_128_0',
    ]

    cfgs_lsu_buf_slots = [
            'sv_4_3x1_3x4_1x1_8_4_128_128_128_0',
            'sv_4_3x1_3x4_1x1_8_6_128_128_128_0',
            'sv_4_3x1_3x4_1x1_8_8_128_128_128_0',
            'sv_4_3x1_3x4_1x1_8_10_128_128_128_0',
            'sv_4_3x1_3x4_1x1_8_12_128_128_128_0',
            'sv_4_3x1_3x4_1x1_8_14_128_128_128_0',
            'sv_4_3x1_3x4_1x1_8_16_128_128_128_0',
            'sv_4_3x1_3x4_1x1_8_18_128_128_128_0',
            'sv_4_3x1_3x4_1x1_8_20_128_128_128_0',
            'sv_4_3x1_3x4_1x1_8_22_128_128_128_0',
            'sv_4_3x1_3x4_1x1_8_24_128_128_128_0',
    ]

    cfgs_fpu_slots = [
            'sv_4_3x1_3x4_1x1_8_4_4_128_128_0',
            'sv_4_3x1_3x4_1x1_8_4_6_128_128_0',
            'sv_4_3x1_3x4_1x1_8_4_8_128_128_0',
            'sv_4_3x1_3x4_1x1_8_4_10_128_128_0',
            'sv_4_3x1_3x4_1x1_8_4_12_128_128_0',
            'sv_4_3x1_3x4_1x1_8_4_14_128_128_0',
            'sv_4_3x1_3x4_1x1_8_4_16_128_128_0',
            'sv_4_3x1_3x4_1x1_8_4_18_128_128_0',
            'sv_4_3x1_3x4_1x1_8_4_20_128_128_0',
            'sv_4_3x1_3x4_1x1_8_4_22_128_128_0',
            'sv_4_3x1_3x4_1x1_8_4_24_128_128_0',
    ]

    cfgs_gpr = [
            'sv_4_3x1_3x4_1x1_8_6_8_36_128_0',
            'sv_4_3x1_3x4_1x1_8_6_8_38_128_0',
            'sv_4_3x1_3x4_1x1_8_6_8_40_128_0',
            'sv_4_3x1_3x4_1x1_8_6_8_42_128_0',
            'sv_4_3x1_3x4_1x1_8_6_8_44_128_0',
            'sv_4_3x1_3x4_1x1_8_6_8_46_128_0',
            'sv_4_3x1_3x4_1x1_8_6_8_48_128_0',
            'sv_4_3x1_3x4_1x1_8_6_8_50_128_0',
            'sv_4_3x1_3x4_1x1_8_6_8_52_128_0',
            'sv_4_3x1_3x4_1x1_8_6_8_54_128_0',
            'sv_4_3x1_3x4_1x1_8_6_8_56_128_0',
            'sv_4_3x1_3x4_1x1_8_6_8_58_128_0',
            'sv_4_3x1_3x4_1x1_8_6_8_60_128_0',
    ]


    cfgs = [
            'sv_4_3x1_3x4_1x1_8_6_8_42_36_0',
            'sv_4_3x1_3x4_1x1_8_6_8_42_38_0',
            'sv_4_3x1_3x4_1x1_8_6_8_42_40_0',
            'sv_4_3x1_3x4_1x1_8_6_8_42_42_0',
            'sv_4_3x1_3x4_1x1_8_6_8_42_44_0',
            'sv_4_3x1_3x4_1x1_8_6_8_42_46_0',
            'sv_4_3x1_3x4_1x1_8_6_8_42_48_0',
            'sv_4_3x1_3x4_1x1_8_6_8_42_50_0',
            'sv_4_3x1_3x4_1x1_8_6_8_42_52_0',
            'sv_4_3x1_3x4_1x1_8_6_8_42_54_0',
            'sv_4_3x1_3x4_1x1_8_6_8_42_56_0',
            'sv_4_3x1_3x4_1x1_8_6_8_42_58_0',
            'sv_4_3x1_3x4_1x1_8_6_8_42_60_0',
    ]

    #cfgs = [
    #    'sv_4_3x1_3x4_1x1_26_12_22_56_52_0',
    #]

    modes = ['superscalar']
    # sizes = [256, 512, 1024, 2048, 4096]
    sizes = [4096]
    app_filter =  None
    core = None

    # Drop failing tests at 256 when running in CI
    # Also drop tests at 512 and 4096, just for CI runtime
    if ci:
        sizes = sizes[2:-1]

    # Generate experiment list
    experiments = []
    for cfg in cfgs:
        # Check if this config targets the schnova core
        is_schnova_core = cfg.startswith('sv')
        core = 'schnova' if is_schnova_core else None
        app_class = _HW_APP_CLASS.get(cfg)
        compatible = set(APPLICATION_CLASS[app_class] if app_class else APPLICATION_CLASS['GP'])
        for mode in modes:
            # Scalar experiments do not depend on the response xbar configuration
            # And it does not make sense to test scalar code with a scalar pipeline in schnova
            if mode == 'scalar':
                if cfg != '3x32_3x32_1x64':
                    continue
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
                                'funcptr': 'dot_schnova',
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
                                # Use an unrolled version of the axpy schnova kernel
                                # Its the same as axpy_baseline but using the superscalar frep mode
                                'funcptr': 'axpy_schnova',
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
                                'func_ptr': 'vexpf_schnova',
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
                                'func_ptr': 'vlogf_schnova',
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
                                    'func_ptr': 'calculate_psum_schnova',
                                },
                                'cmd': [str(MK_DIR / 'sw/kernels/misc/montecarlo/pi_estimation/scripts/verify.py'),  # noqa: E501
                                        sim_bin, "${elf}"],
                                'roi': Path("roi/pi_estimation.json.tpl")
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
    df['ipc'] = df.apply(lambda row: row['results'].get_metric(roi, 'ipc'), axis=1)
    df['fpu_util'] = df.apply(lambda row: row['results'].get_metric(roi, 'fpu_util'), axis=1)
    return df


def main():
    parser = ExperimentManager.parser()
    parser.add_argument('--ci', action='store_true', help='Reduce number of experiments for CI')
    args = parser.parse_args()
    experiments = gen_experiments(ci=args.ci)
    manager = ExperimentManager(experiments=experiments, args=args, parse_args=False)

    manager.run()


if __name__ == '__main__':
    main()
