#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments.SimResults import SimRegion
from snitch.util.experiments import experiment_utils as eu
from snitch.util.experiments.common import MK_DIR
from pathlib import Path

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
        return Path.cwd() / f"cfg_pw4/{experiment['hw']}.json"

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
        if experiment['app'] == 'eltwise':
            cdefines['SPLIT_ELTWISE_FNS'] = 1
        if experiment['app'] == 'softmax':
            cdefines['SOFTMAX_FUNC_PTR'] = 'softmax_fp32_schnova'
        if (experiment['hw'].startswith('sv_1') or
            experiment['hw'].startswith('sv_2')):
            cdefines['UNROLL'] = 1
        if (experiment['bal'] == True):
            cdefines['BALANCE_INSTRUCTION_MIX'] = 1
        return cdefines

    def derive_env(self, experiment):
        env = super().derive_env(experiment)
        if experiment['app'] in DNN_APPS:
            env['SN_HW_FDIV'] = '1'
        return env

def gen_experiments(vary_by=None, use_rob=False, use_bal=False):
    # Define experiment axes
    cfgs = []

    alu_slots_cfgs = [
        'sv_4_3x1_3x128_1x128_128_128_128_128_128_0',
        'sv_4_3x2_3x128_1x128_128_128_128_128_128_0',
        'sv_4_3x3_3x128_1x128_128_128_128_128_128_0',
        'sv_4_3x4_3x128_1x128_128_128_128_128_128_0',
        'sv_4_3x5_3x128_1x128_128_128_128_128_128_0',
    ]

    lsu_slots_cfgs = [
        'sv_4_3x1_3x1_1x128_128_128_128_128_128_0',
        'sv_4_3x1_3x2_1x128_128_128_128_128_128_0',
        'sv_4_3x1_3x3_1x128_128_128_128_128_128_0',
        'sv_4_3x1_3x4_1x128_128_128_128_128_128_0',
        'sv_4_3x1_3x5_1x128_128_128_128_128_128_0',
    ]

    fpu_slots_cfgs = [
        'sv_4_3x1_3x4_1x1_128_128_128_128_128_0',
        'sv_4_3x1_3x4_1x2_128_128_128_128_128_0',
        'sv_4_3x1_3x4_1x3_128_128_128_128_128_0',
        'sv_4_3x1_3x4_1x4_128_128_128_128_128_0',
        'sv_4_3x1_3x4_1x5_128_128_128_128_128_0',
    ]

    alu_buf_slots_cfgs = [
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

    alu_buf_slots_bal_cfgs = [
        'sv_4_3x1_3x4_1x1_4_128_128_128_128_0',
        'sv_4_3x1_3x4_1x1_6_128_128_128_128_0',
        'sv_4_3x1_3x4_1x1_8_128_128_128_128_0',
        'sv_4_3x1_3x4_1x1_10_128_128_128_128_0',
        'sv_4_3x1_3x4_1x1_12_128_128_128_128_0',
        'sv_4_3x1_3x4_1x1_14_128_128_128_128_0',
        'sv_4_3x1_3x4_1x1_16_128_128_128_128_0',
        'sv_4_3x1_3x4_1x1_18_128_128_128_128_0',
        'sv_4_3x1_3x4_1x1_20_128_128_128_128_0',
    ]

    lsu_buf_slots_cfgs = [
        'sv_4_3x1_3x4_1x1_16_8_128_128_128_0',
        'sv_4_3x1_3x4_1x1_16_10_128_128_128_0',
        'sv_4_3x1_3x4_1x1_16_12_128_128_128_0',
        'sv_4_3x1_3x4_1x1_16_14_128_128_128_0',
        'sv_4_3x1_3x4_1x1_16_16_128_128_128_0',
        'sv_4_3x1_3x4_1x1_16_18_128_128_128_0',
        'sv_4_3x1_3x4_1x1_16_20_128_128_128_0',
        'sv_4_3x1_3x4_1x1_16_22_128_128_128_0',
        'sv_4_3x1_3x4_1x1_16_24_128_128_128_0',
        'sv_4_3x1_3x4_1x1_16_26_128_128_128_0',
        'sv_4_3x1_3x4_1x1_16_28_128_128_128_0',
        'sv_4_3x1_3x4_1x1_16_30_128_128_128_0',
    ]

    fpu_buf_slots_cfgs = [
        'sv_4_3x1_3x4_1x1_16_12_8_128_128_0',
        'sv_4_3x1_3x4_1x1_16_12_10_128_128_0',
        'sv_4_3x1_3x4_1x1_16_12_12_128_128_0',
        'sv_4_3x1_3x4_1x1_16_12_14_128_128_0',
        'sv_4_3x1_3x4_1x1_16_12_16_128_128_0',
        'sv_4_3x1_3x4_1x1_16_12_18_128_128_0',
        'sv_4_3x1_3x4_1x1_16_12_20_128_128_0',
        'sv_4_3x1_3x4_1x1_16_12_22_128_128_0',
        'sv_4_3x1_3x4_1x1_16_12_24_128_128_0',
        'sv_4_3x1_3x4_1x1_16_12_26_128_128_0',
        'sv_4_3x1_3x4_1x1_16_12_28_128_128_0',
        'sv_4_3x1_3x4_1x1_16_12_30_128_128_0',
    ]

    rfcnt_gpr_cfgs = [
       'sv_4_3x1_3x4_1x1_16_12_30_46_128_0',
       'sv_4_3x1_3x4_1x1_16_12_30_48_128_0',
       #'sv_4_3x1_3x4_1x1_16_12_30_50_128_0',
       #'sv_4_3x1_3x4_1x1_16_12_30_52_128_0',
       'sv_4_3x1_3x4_1x1_16_12_30_54_128_0',
       'sv_4_3x1_3x4_1x1_16_12_30_56_128_0',
       #'sv_4_3x1_3x4_1x1_16_12_30_58_128_0',
       #'sv_4_3x1_3x4_1x1_16_12_30_60_128_0',
       'sv_4_3x1_3x4_1x1_16_12_30_62_128_0',
       #'sv_4_3x1_3x4_1x1_16_12_30_64_128_0',
       'sv_4_3x1_3x4_1x1_16_12_30_66_128_0',
       #'sv_4_3x1_3x4_1x1_16_12_30_68_128_0',
       #'sv_4_3x1_3x4_1x1_16_12_30_70_128_0',
    ]

    rfcnt_fpr_cfgs = [
       'sv_4_3x1_3x4_1x1_16_12_30_52_46_0',
       'sv_4_3x1_3x4_1x1_16_12_30_52_48_0',
       'sv_4_3x1_3x4_1x1_16_12_30_52_50_0',
       'sv_4_3x1_3x4_1x1_16_12_30_52_52_0',
       'sv_4_3x1_3x4_1x1_16_12_30_52_54_0',
       'sv_4_3x1_3x4_1x1_16_12_30_52_56_0', 
       'sv_4_3x1_3x4_1x1_16_12_30_52_58_0',
       'sv_4_3x1_3x4_1x1_16_12_30_52_60_0',
       'sv_4_3x1_3x4_1x1_16_12_30_52_62_0',
       'sv_4_3x1_3x4_1x1_16_12_30_52_64_0',
       'sv_4_3x1_3x4_1x1_16_12_30_52_66_0',
       'sv_4_3x1_3x4_1x1_16_12_30_52_68_0',
       'sv_4_3x1_3x4_1x1_16_12_30_52_70_0',
    ]

    rob_gpr_cfgs = [
       'sv_4_3x1_3x4_1x1_16_12_30_96_128_256',
       'sv_4_3x1_3x4_1x1_16_12_30_98_128_256',
       'sv_4_3x1_3x4_1x1_16_12_30_100_128_256',
       'sv_4_3x1_3x4_1x1_16_12_30_102_128_256',
       'sv_4_3x1_3x4_1x1_16_12_30_104_128_256',
       'sv_4_3x1_3x4_1x1_16_12_30_106_128_256',
       'sv_4_3x1_3x4_1x1_16_12_30_108_128_256',
       'sv_4_3x1_3x4_1x1_16_12_30_110_128_256',
       'sv_4_3x1_3x4_1x1_16_12_30_112_128_256',
       'sv_4_3x1_3x4_1x1_16_12_30_114_128_256',
       'sv_4_3x1_3x4_1x1_16_12_30_116_128_256',
       'sv_4_3x1_3x4_1x1_16_12_30_118_128_256',
       'sv_4_3x1_3x4_1x1_16_12_30_120_128_256',
    ]

    rob_fpr_cfgs = [
       'sv_4_3x1_3x4_1x1_16_12_30_114_56_256',
       'sv_4_3x1_3x4_1x1_16_12_30_114_58_256',
       'sv_4_3x1_3x4_1x1_16_12_30_114_60_256',
       'sv_4_3x1_3x4_1x1_16_12_30_114_62_256',
       'sv_4_3x1_3x4_1x1_16_12_30_114_64_256',
       'sv_4_3x1_3x4_1x1_16_12_30_114_66_256', 
       'sv_4_3x1_3x4_1x1_16_12_30_114_68_256',
       'sv_4_3x1_3x4_1x1_16_12_30_114_70_256',
       'sv_4_3x1_3x4_1x1_16_12_30_114_72_256',
       'sv_4_3x1_3x4_1x1_16_12_30_114_74_256',
       'sv_4_3x1_3x4_1x1_16_12_30_114_76_256',
       'sv_4_3x1_3x4_1x1_16_12_30_114_78_256',
       'sv_4_3x1_3x4_1x1_16_12_30_114_80_256',
    ]

    rob_cfgs = [
                'sv_4_3x1_3x4_1x1_16_12_30_114_68_16',
                'sv_4_3x1_3x4_1x1_16_12_30_114_68_32',
                'sv_4_3x1_3x4_1x1_16_12_30_114_68_64',
                'sv_4_3x1_3x4_1x1_16_12_30_114_68_128',
                'sv_4_3x1_3x4_1x1_16_12_30_114_68_256',
    ]

    large_cfg = [
        'sv_8_3x128_3x128_1x128_128_128_128_128_128_0'
    ]

    if (vary_by == 'alu_slots'):
        cfgs = alu_slots_cfgs
    elif (vary_by == 'lsu_slots'):
        cfgs = lsu_slots_cfgs
    elif (vary_by == 'fpu_slots'):
        cfgs = fpu_slots_cfgs
    elif (vary_by == 'alu_buf_slots'):
        if use_bal:
            cfgs = alu_buf_slots_bal_cfgs
        else:
            cfgs = alu_buf_slots_cfgs
    elif (vary_by == 'lsu_buf_slots'):
        cfgs = lsu_buf_slots_cfgs
    elif (vary_by == 'fpu_buf_slots'):
        cfgs = fpu_buf_slots_cfgs
    elif (vary_by == 'gpr'):
        if use_rob:
            cfgs = rob_gpr_cfgs
        else:
            cfgs = rfcnt_gpr_cfgs
    elif (vary_by == 'fpr'):
        if use_rob:
            cfgs = rob_fpr_cfgs
        else:
            cfgs = rfcnt_fpr_cfgs
    elif (vary_by == 'rob_entries'):
        cfgs = rob_cfgs
    else :
        cfgs = large_cfg

    modes = [
             'superscalar'
             ]
    sizes = [4096]
    app_filter = None
    core = 'schnova'

    # Generate experiment list
    experiments = []
    for cfg in cfgs:
        core = 'schnova'
        bal  = True if cfg.endswith('bal') else False
        for mode in modes:
            for size in sizes:
                sim_bin = str(Path.cwd() / 'hw' / cfg / 'bin/snitch_cluster.vsim')
                experiments.extend([
                    {
                        'app': 'sz_dot',
                        'hw': cfg,
                        'mode': mode,
                        'core': core,
                        'bal' : bal,
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
                        'bal' : bal,
                        'data_cfg': {
                            'n': size,
                            'funcptr': 'axpy_schnova',
                        },
                        'cmd': [str(MK_DIR / 'sw/kernels/blas/sz_axpy/scripts/verify.py'),
                                sim_bin, "${elf}"],
                        'roi': Path("roi/sz_axpy_roi.json.tpl")
                    },
                ])
                experiments.extend([
                    {
                        'app': 'exp',
                        'hw': cfg,
                        'mode': mode,
                        'core': core,
                        'bal' : bal,
                        'data_cfg': {
                            'len': size,
                            'batch_size': size,
                            'func_ptr': 'vexpf_schnova'
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
                        'bal' : bal,
                        'data_cfg': {
                            'len': size,
                            'batch_size': size,
                            'func_ptr': 'vlogf_schnova'
                        },
                        'cmd': [str(MK_DIR / 'sw/kernels/misc/log/scripts/verify.py'),
                                sim_bin, "${elf}"],
                        'roi': Path("roi/log.json.tpl")
                    },
                ])
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
                            'bal' : bal,
                            'data_cfg': {
                                'n': size,
                                'func_ptr': 'calculate_psum_schnova',
                            },
                            'cmd': [str(MK_DIR / 'sw/kernels/misc/montecarlo/pi_estimation/scripts/verify.py'),  # noqa: E501
                                    sim_bin, "${elf}"],
                            'roi': Path("roi/pi_estimation.json.tpl")
                        })
                for app in DNN_SIMPLE_APPS:
                    verify = MK_DIR / f"sw/kernels/dnn/{app}/scripts/verify.py"
                    cmd = [str(verify), sim_bin, "${elf}"] if verify.exists() else [sim_bin, "${elf}"]
                    experiments.append({
                        'app': app,
                        'hw': cfg,
                        'mode': mode,
                        'core': core,
                        'bal': bal,
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
                        'bal' : bal,
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


def results(vary_by, use_rob=False, use_bal=False, dir=None):
    df = ExperimentManager(gen_experiments(vary_by, use_rob, use_bal), dir=dir, parse_args=False).get_results()
    roi = SimRegion('hart_0', 'compute')
    df['ipc'] = df.apply(lambda row: row['results'].get_metric(roi, 'ipc'), axis=1)
    df['fpu_util'] = df.apply(lambda row: row['results'].get_metric(roi, 'fpu_util'), axis=1)
    return df


def main():
    parser = ExperimentManager.parser()
    parser.add_argument(
        "--vary",
        choices=["alus",
                 "lsus",
                 "fpus",
                 "alu_slots",
                 "lsu_slots",
                 "fpu_slots",
                 "alu_buf_slots",
                 "lsu_buf_slots",
                 "fpu_buf_slots",
                 "gpr",
                 "fpr",
                 "rob_entries"],
        default="slots",
        help="Which hardware parameter to vary for the experiments (default: slots)"
    )
    parser.add_argument(
        "--use_rob",
        action="store_true",  # Sets to True if present, False if absent
        help="Use a ROB instead of reference counting for the register size experiments."
    )
    parser.add_argument(
        "--use_bal",
        action="store_true",  # Sets to True if present, False if absent
        help="Use a balanced instruction mix for the software kernels."
    )
    args = parser.parse_args()
    vary_by = vars(args).pop('vary', None)
    use_rob  = vars(args).pop('use_rob', 0)
    use_bal  = vars(args).pop('use_bal', 0)
    experiments = gen_experiments(vary_by, use_rob, use_bal)
    
    manager = ExperimentManager(experiments=experiments, args=args, parse_args=False)

    manager.run()


if __name__ == '__main__':
    main()
