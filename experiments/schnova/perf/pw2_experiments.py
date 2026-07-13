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
        return Path.cwd() / f"cfg_pw2/{experiment['hw']}.json"

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
        'sv_2_2x1_2x128_1x128_128_128_128_128_128_0',
        'sv_2_2x2_2x128_1x128_128_128_128_128_128_0',
        'sv_2_2x3_2x128_1x128_128_128_128_128_128_0',
        'sv_2_2x4_2x128_1x128_128_128_128_128_128_0',
        'sv_2_2x5_2x128_1x128_128_128_128_128_128_0',
    ]

    lsu_slots_cfgs = [
        'sv_2_2x1_2x1_1x128_128_128_128_128_128_0',
        'sv_2_2x1_2x2_1x128_128_128_128_128_128_0',
        'sv_2_2x1_2x3_1x128_128_128_128_128_128_0',
        'sv_2_2x1_2x4_1x128_128_128_128_128_128_0',
        'sv_2_2x1_2x5_1x128_128_128_128_128_128_0',
    ]

    fpu_slots_cfgs = [
        'sv_2_2x1_2x4_1x1_128_128_128_128_128_0',
        'sv_2_2x1_2x4_1x2_128_128_128_128_128_0',
        'sv_2_2x1_2x4_1x3_128_128_128_128_128_0',
        'sv_2_2x1_2x4_1x4_128_128_128_128_128_0',
        'sv_2_2x1_2x4_1x5_128_128_128_128_128_0',
    ]

    alu_buf_slots_cfgs = [
        'sv_2_2x1_2x4_1x1_8_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_10_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_12_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_14_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_16_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_18_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_20_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_22_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_24_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_26_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_28_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_30_128_128_128_128_0',
    ]

    alu_buf_slots_bal_cfgs = [
        'sv_2_2x1_2x4_1x1_2_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_4_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_6_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_8_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_10_128_128_128_128_0',
        'sv_2_2x1_2x4_1x1_12_128_128_128_128_0',
    ]

    lsu_buf_slots_cfgs = [
        'sv_2_2x1_2x4_1x1_18_8_128_128_128_0',
        'sv_2_2x1_2x4_1x1_18_10_128_128_128_0',
        'sv_2_2x1_2x4_1x1_18_12_128_128_128_0',
        'sv_2_2x1_2x4_1x1_18_14_128_128_128_0',
        'sv_2_2x1_2x4_1x1_18_16_128_128_128_0',
        'sv_2_2x1_2x4_1x1_18_18_128_128_128_0',
        'sv_2_2x1_2x4_1x1_18_20_128_128_128_0',
        'sv_2_2x1_2x4_1x1_18_22_128_128_128_0',
        'sv_2_2x1_2x4_1x1_18_24_128_128_128_0',
        'sv_2_2x1_2x4_1x1_18_26_128_128_128_0',
        'sv_2_2x1_2x4_1x1_18_28_128_128_128_0',
        'sv_2_2x1_2x4_1x1_18_30_128_128_128_0',
    ]

    lsu_buf_slots_bal_cfgs = [
        'sv_2_2x1_2x4_1x1_10_2_128_128_128_0',
        'sv_2_2x1_2x4_1x1_10_4_128_128_128_0',
        'sv_2_2x1_2x4_1x1_10_6_128_128_128_0',
        'sv_2_2x1_2x4_1x1_10_8_128_128_128_0',
        'sv_2_2x1_2x4_1x1_10_10_128_128_128_0',
        'sv_2_2x1_2x4_1x1_10_12_128_128_128_0',
    ]

    fpu_buf_slots_cfgs = [
        'sv_2_2x1_2x4_1x1_18_12_8_128_128_0',
        'sv_2_2x1_2x4_1x1_18_12_10_128_128_0',
        'sv_2_2x1_2x4_1x1_18_12_12_128_128_0',
        'sv_2_2x1_2x4_1x1_18_12_14_128_128_0',
        'sv_2_2x1_2x4_1x1_18_12_16_128_128_0',
        'sv_2_2x1_2x4_1x1_18_12_18_128_128_0',
        'sv_2_2x1_2x4_1x1_18_12_20_128_128_0',
        'sv_2_2x1_2x4_1x1_18_12_22_128_128_0',
        'sv_2_2x1_2x4_1x1_18_12_24_128_128_0',
        'sv_2_2x1_2x4_1x1_18_12_26_128_128_0',
        'sv_2_2x1_2x4_1x1_18_12_28_128_128_0',
        'sv_2_2x1_2x4_1x1_18_12_30_128_128_0',
    ]

    fpu_buf_slots_bal_cfgs = [
        'sv_2_2x1_2x4_1x1_10_6_2_128_128_0',
        'sv_2_2x1_2x4_1x1_10_6_4_128_128_0',
        'sv_2_2x1_2x4_1x1_10_6_6_128_128_0',
        'sv_2_2x1_2x4_1x1_10_6_8_128_128_0',
        'sv_2_2x1_2x4_1x1_10_6_10_128_128_0',
        'sv_2_2x1_2x4_1x1_10_6_12_128_128_0',
    ]

    rfcnt_gpr_cfgs = [
       'sv_2_2x1_2x4_1x1_18_12_24_46_128_0',
       'sv_2_2x1_2x4_1x1_18_12_24_48_128_0',
       'sv_2_2x1_2x4_1x1_18_12_24_50_128_0',
       'sv_2_2x1_2x4_1x1_18_12_24_52_128_0',
       'sv_2_2x1_2x4_1x1_18_12_24_54_128_0',
       'sv_2_2x1_2x4_1x1_18_12_24_56_128_0',
       'sv_2_2x1_2x4_1x1_18_12_24_58_128_0',
       'sv_2_2x1_2x4_1x1_18_12_24_60_128_0',
       'sv_2_2x1_2x4_1x1_18_12_24_62_128_0',
       'sv_2_2x1_2x4_1x1_18_12_24_64_128_0',
       'sv_2_2x1_2x4_1x1_18_12_24_66_128_0',
       'sv_2_2x1_2x4_1x1_18_12_24_68_128_0',
       'sv_2_2x1_2x4_1x1_18_12_24_70_128_0',
    ]

    rfcnt_gpr_bal_cfgs = [
        'sv_2_2x1_2x4_1x1_10_6_8_34_128_0',
        'sv_2_2x1_2x4_1x1_10_6_8_36_128_0',
        'sv_2_2x1_2x4_1x1_10_6_8_38_128_0',
        'sv_2_2x1_2x4_1x1_10_6_8_40_128_0',
        'sv_2_2x1_2x4_1x1_10_6_8_42_128_0',
        'sv_2_2x1_2x4_1x1_10_6_8_44_128_0',
        'sv_2_2x1_2x4_1x1_10_6_8_46_128_0',
        'sv_2_2x1_2x4_1x1_10_6_8_48_128_0',
        'sv_2_2x1_2x4_1x1_10_6_8_50_128_0',
    ]

    rfcnt_fpr_cfgs = [
       'sv_2_2x1_2x4_1x1_18_12_24_52_46_0',
       'sv_2_2x1_2x4_1x1_18_12_24_52_48_0',
       'sv_2_2x1_2x4_1x1_18_12_24_52_50_0',
       'sv_2_2x1_2x4_1x1_18_12_24_52_52_0',
       'sv_2_2x1_2x4_1x1_18_12_24_52_54_0',
       'sv_2_2x1_2x4_1x1_18_12_24_52_56_0', 
       'sv_2_2x1_2x4_1x1_18_12_24_52_58_0',
       'sv_2_2x1_2x4_1x1_18_12_24_52_60_0',
       'sv_2_2x1_2x4_1x1_18_12_24_52_62_0',
       'sv_2_2x1_2x4_1x1_18_12_24_52_64_0',
       'sv_2_2x1_2x4_1x1_18_12_24_52_66_0',
       'sv_2_2x1_2x4_1x1_18_12_24_52_68_0',
       'sv_2_2x1_2x4_1x1_18_12_24_52_70_0',
    ]

    rfcnt_fpr_bal_cfgs = [
        'sv_2_2x1_2x4_1x1_10_6_8_44_34_0',
        'sv_2_2x1_2x4_1x1_10_6_8_44_36_0',
        'sv_2_2x1_2x4_1x1_10_6_8_44_38_0',
        'sv_2_2x1_2x4_1x1_10_6_8_44_40_0',
        'sv_2_2x1_2x4_1x1_10_6_8_44_42_0',
        'sv_2_2x1_2x4_1x1_10_6_8_44_44_0',
        'sv_2_2x1_2x4_1x1_10_6_8_44_46_0',
    ]

    rob_gpr_cfgs = [
       'sv_2_2x1_2x4_1x1_18_12_24_76_128_256',
       'sv_2_2x1_2x4_1x1_18_12_24_78_128_256',
       'sv_2_2x1_2x4_1x1_18_12_24_80_128_256',
       'sv_2_2x1_2x4_1x1_18_12_24_82_128_256',
       'sv_2_2x1_2x4_1x1_18_12_24_84_128_256',
       'sv_2_2x1_2x4_1x1_18_12_24_86_128_256',
       'sv_2_2x1_2x4_1x1_18_12_24_88_128_256',
       'sv_2_2x1_2x4_1x1_18_12_24_90_128_256',
       'sv_2_2x1_2x4_1x1_18_12_24_92_128_256',
       'sv_2_2x1_2x4_1x1_18_12_24_94_128_256',
       'sv_2_2x1_2x4_1x1_18_12_24_96_128_256',
       'sv_2_2x1_2x4_1x1_18_12_24_98_128_256',
       'sv_2_2x1_2x4_1x1_18_12_24_100_128_256',
    ]

    rob_fpr_cfgs = [
       'sv_2_2x1_2x4_1x1_18_12_24_92_56_256',
       'sv_2_2x1_2x4_1x1_18_12_24_92_58_256',
       'sv_2_2x1_2x4_1x1_18_12_24_92_60_256',
       'sv_2_2x1_2x4_1x1_18_12_24_92_62_256',
       'sv_2_2x1_2x4_1x1_18_12_24_92_64_256',
       'sv_2_2x1_2x4_1x1_18_12_24_92_66_256',
       'sv_2_2x1_2x4_1x1_18_12_24_92_68_256',
       'sv_2_2x1_2x4_1x1_18_12_24_92_70_256',
       'sv_2_2x1_2x4_1x1_18_12_24_92_72_256',
       'sv_2_2x1_2x4_1x1_18_12_24_92_74_256',
       'sv_2_2x1_2x4_1x1_18_12_24_92_76_256',
       'sv_2_2x1_2x4_1x1_18_12_24_92_78_256',
       'sv_2_2x1_2x4_1x1_18_12_24_92_80_256',
    ]

    rob_cfgs = [
                'sv_2_2x1_2x4_1x1_18_12_24_92_80_16',
                'sv_2_2x1_2x4_1x1_18_12_24_92_80_32',
                'sv_2_2x1_2x4_1x1_18_12_24_92_80_64',
                'sv_2_2x1_2x4_1x1_18_12_24_92_80_128',
                'sv_2_2x1_2x4_1x1_18_12_24_92_80_256',
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
        if use_bal:
            cfgs = lsu_buf_slots_bal_cfgs
        else:
            cfgs = lsu_buf_slots_cfgs
    elif (vary_by == 'fpu_buf_slots'):
        if use_bal:
            cfgs = fpu_buf_slots_bal_cfgs
        else:
            cfgs = fpu_buf_slots_cfgs
    elif (vary_by == 'gpr'):
        if use_rob:
            cfgs = rob_gpr_cfgs
        else:
            if use_bal:
                cfgs = rfcnt_gpr_bal_cfgs
            else:
                cfgs = rfcnt_gpr_cfgs
    elif (vary_by == 'fpr'):
        if use_rob:
            cfgs = rob_fpr_cfgs
        else:
            if use_bal:
                cfgs = rfcnt_fpr_bal_cfgs
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
        bal  = use_bal
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
