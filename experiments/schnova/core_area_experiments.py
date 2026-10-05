#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments import experiment_utils as eu

EARLY_SYNTH_STAGE = '7'
FINAL_SYNTH_STAGE = '9'


def schnova_keep_hier(hdl_params):
    """Hierarchical instance paths of the cells to keep when grouping a Schnova core.

    Generate scopes are flattened by the synthesis tool into the instance name, e.g.
    `gen_alus_0__i_alu`, so the FU paths depend on the HDL parameters. Paths which don't
    exist in a given configuration (e.g. the renaming logic in Schnova-ZOL) are harmless.
    """
    core = 'i_schnova'
    dispatcher = f'{core}/i_dispatcher/gen_rs_dispatcher_i_rs_dispatcher'
    fus = [
        (f'{core}/i_fu_stage/gen_{fu}s_{i}__', fu)
        for fu in ('alu', 'lsu', 'fpu')
        for i in range(hdl_params[f'Nof{fu.capitalize()}s'])
    ]

    return [
        f'{core}/i_frontend',
        f'{core}/i_decoder',
        f'{core}/i_read_operands',
        f'{core}/i_dispatcher',
        f'{core}/i_int_phy_regfile',
        f'{core}/gen_fp_rf_i_fp_phy_regfile',
        f'{core}/gen_rename_i_rename',
        f'{core}/gen_phys_reg_manage_gen_refcount_reg_manage_i_refcount',
        f'{core}/i_fu_stage',
        *[f'{path}i_{fu}' for path, fu in fus],
        *[f'{path}gen_rs_i_res_stat' for path, _ in fus],
        *[f'{dispatcher}/{fu}_disp_buffer' for fu in ('alu', 'lsu', 'fpu')],
    ]


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        axes = eu.derive_axes_from_keys(experiment, keys=['name'])
        axes['grouping'] = 'grouped' if experiment['grouped'] else 'ungrouped'
        return axes


def gen_experiments(designs=None):
    # Generate list of experiments
    # IMPORTANT: HDL parameters should be listed in the same order they appear in the RTL
    experiments = [
        # {
        #     'design': 'snitch_synth',
        #     'name': 'snitch'
        # },
        # {
        #     'design': 'schnizo_synth',
        #     'name': 'Schnizo',
        #     'hdl_params': {
        #         'Xfrep': 0,
        #         'NofAlus': 1,
        #         'NofLsus': 1,
        #         'NofFpus': 0,
        #         'MulInAlu0': 1,
        #     }
        # },
        # {
        #     'design': 'schnizo_synth',
        #     'name': 'Schnizo-FP',
        #     'hdl_params': {
        #         'Xfrep': 0,
        #         'NofAlus': 1,
        #         'NofLsus': 1,
        #         'NofFpus': 1,
        #     }
        # },
        # {
        #     'design':   'schnova_synth',
        #     'name':     'Schnova',
        #     'hdl_params': {
        #         'XFREPI': 0,
        #         'XFREPO': 0,
        #         'NofAlus': 1,
        #         'NofLsus': 1,
        #         'NofFpus': 0,
        #         'NofAluBufEntries': 1,
        #         'NofLsuBufEntries': 1,
        #         'NofFpuBufEntries': 1,
        #         'AluNofRss': 1,
        #         'LsuNofRss': 1,
        #         'FpuNofRss': 1,
        #         'ICacheFetchDataWidth': 32,
        #         'NofPhysGpr': 32,
        #         'NofPhysFpr': 32,
        #         'NofRobEntries': 1,
        #         'UseFreeList': 0,
        #     }
        # },
        # {
        #     'design':   'schnova_synth',
        #     'name':     'Schnova-FP',
        #     'hdl_params': {
        #         'XFREPI': 0,
        #         'XFREPO': 0,
        #         'NofAlus': 1,
        #         'NofLsus': 1,
        #         'NofFpus': 1,
        #         'NofAluBufEntries': 1,
        #         'NofLsuBufEntries': 1,
        #         'NofFpuBufEntries': 1,
        #         'AluNofRss': 1,
        #         'LsuNofRss': 1,
        #         'FpuNofRss': 1,
        #         'ICacheFetchDataWidth': 32,
        #         'NofPhysGpr': 32,
        #         'NofPhysFpr': 32,
        #         'NofRobEntries': 1,
        #         'UseFreeList': 0,
        #     }
        # },
        # {
        #     'design':   'schnova_synth',
        #     'name':     'Schnova-ZOL',
        #     'hdl_params': {
        #         'XFREPI': 1,
        #         'XFREPO': 0,
        #         'NofAlus': 1,
        #         'NofLsus': 1,
        #         'NofFpus': 1,
        #         'NofAluBufEntries': 1,
        #         'NofLsuBufEntries': 1,
        #         'NofFpuBufEntries': 1,
        #         'AluNofRss': 1,
        #         'LsuNofRss': 1,
        #         'FpuNofRss': 1,
        #         'ICacheFetchDataWidth': 32,
        #         'NofPhysGpr': 32,
        #         'NofPhysFpr': 32,
        #         'NofRobEntries': 1,
        #         'UseFreeList': 0,
        #     }
        # },
        {
            'design':   'schnova_synth',
            'name':     'Schnova-ZOL',
            'grouped':   True,
            'hdl_params': {
                'XFREPI': 1,
                'XFREPO': 0,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
                'NofAluBufEntries': 1,
                'NofLsuBufEntries': 1,
                'NofFpuBufEntries': 1,
                'AluNofRss': 1,
                'LsuNofRss': 1,
                'FpuNofRss': 1,
                'ICacheFetchDataWidth': 32,
                'NofPhysGpr': 32,
                'NofPhysFpr': 32,
                'NofRobEntries': 1,
                'UseFreeList': 0,
            }
        },
        # {
        #     'design':   'schnova_synth',
        #     'name':     'GP-PW1',
        #     'hdl_params': {
        #         'XFREPI': 1,
        #         'XFREPO': 1,
        #         'NofAlus': 1,
        #         'NofLsus': 1,
        #         'NofFpus': 1,
        #         'NofAluBufEntries': 4,
        #         'NofLsuBufEntries': 2,
        #         'NofFpuBufEntries': 6,
        #         'AluNofRss': 1,
        #         'LsuNofRss': 1,
        #         'FpuNofRss': 1,
        #         'ICacheFetchDataWidth': 32,
        #         'NofPhysGpr': 38,
        #         'NofPhysFpr': 38,
        #         'NofRobEntries': 1,
        #         'UseFreeList': 0,
        #     }
        # },
        # {
        #     'design':   'schnova_synth',
        #     'name':     'GP-PW2',
        #     'hdl_params': {
        #         'XFREPI': 1,
        #         'XFREPO': 1,
        #         'NofAlus': 2,
        #         'NofLsus': 2,
        #         'NofFpus': 1,
        #         'NofAluBufEntries': 18,
        #         'NofLsuBufEntries': 14,
        #         'NofFpuBufEntries': 24,
        #         'AluNofRss': 1,
        #         'LsuNofRss': 4,
        #         'FpuNofRss': 1,
        #         'ICacheFetchDataWidth': 64,
        #         'NofPhysGpr': 52,
        #         'NofPhysFpr': 54,
        #         'NofRobEntries': 1,
        #         'UseFreeList': 0,
        #     }
        # },
        {
            'design':   'schnova_synth',
            'name':     'GP-PW2',
            'grouped':  True,
            'hdl_params': {
                'XFREPI': 1,
                'XFREPO': 1,
                'NofAlus': 2,
                'NofLsus': 2,
                'NofFpus': 1,
                'NofAluBufEntries': 18,
                'NofLsuBufEntries': 14,
                'NofFpuBufEntries': 24,
                'AluNofRss': 1,
                'LsuNofRss': 4,
                'FpuNofRss': 1,
                'ICacheFetchDataWidth': 64,
                'NofPhysGpr': 52,
                'NofPhysFpr': 54,
                'NofRobEntries': 1,
                'UseFreeList': 0,
            }
        },
        # {
        #     'design':   'schnova_synth',
        #     'name':     'GP-PW4',
        #     'hdl_params': {
        #         'XFREPI': 1,
        #         'XFREPO': 1,
        #         'NofAlus': 3,
        #         'NofLsus': 3,
        #         'NofFpus': 1,
        #         'NofAluBufEntries': 16,
        #         'NofLsuBufEntries': 12,
        #         'NofFpuBufEntries': 30,
        #         'AluNofRss': 1,
        #         'LsuNofRss': 4,
        #         'FpuNofRss': 1,
        #         'ICacheFetchDataWidth': 128,
        #         'NofPhysGpr': 52,
        #         'NofPhysFpr': 56,
        #         'NofRobEntries': 1,
        #         'UseFreeList': 0,
        #     }
        # },
        # {
        #     'design':   'schnova_synth',
        #     'name':     'GP-PW8',
        #     'hdl_params': {
        #         'XFREPI': 1,
        #         'XFREPO': 1,
        #         'NofAlus': 3,
        #         'NofLsus': 3,
        #         'NofFpus': 1,
        #         'NofAluBufEntries': 16,
        #         'NofLsuBufEntries': 8,
        #         'NofFpuBufEntries': 28,
        #         'AluNofRss': 1,
        #         'LsuNofRss': 8,
        #         'FpuNofRss': 1,
        #         'ICacheFetchDataWidth': 256,
        #         'NofPhysGpr': 52,
        #         'NofPhysFpr': 54,
        #         'NofRobEntries': 1,
        #         'UseFreeList': 0,
        #     }
        # },
        # {
        #     'design':   'schnova_synth',
        #     'name':     'LA-PW1',
        #     'hdl_params': {
        #         'XFREPI': 1,
        #         'XFREPO': 1,
        #         'NofAlus': 1,
        #         'NofLsus': 1,
        #         'NofFpus': 1,
        #         'NofAluBufEntries': 2,
        #         'NofLsuBufEntries': 2,
        #         'NofFpuBufEntries': 2,
        #         'AluNofRss': 1,
        #         'LsuNofRss': 1,
        #         'FpuNofRss': 1,
        #         'ICacheFetchDataWidth': 32,
        #         'NofPhysGpr': 34,
        #         'NofPhysFpr': 34,
        #         'NofRobEntries': 1,
        #         'UseFreeList': 0,
        #     }
        # },
        # {
        #     'design':   'schnova_synth',
        #     'name':     'LA-PW2',
        #     'hdl_params': {
        #         'XFREPI': 1,
        #         'XFREPO': 1,
        #         'NofAlus': 2,
        #         'NofLsus': 2,
        #         'NofFpus': 1,
        #         'NofAluBufEntries': 2,
        #         'NofLsuBufEntries': 4,
        #         'NofFpuBufEntries': 4,
        #         'AluNofRss': 1,
        #         'LsuNofRss': 1,
        #         'FpuNofRss': 1,
        #         'ICacheFetchDataWidth': 64,
        #         'NofPhysGpr': 34,
        #         'NofPhysFpr': 38,
        #         'NofRobEntries': 1,
        #         'UseFreeList': 0,
        #     }
        # },
        # {
        #     'design':   'schnova_synth',
        #     'name':     'LA-PW4',
        #     'hdl_params': {
        #         'XFREPI': 1,
        #         'XFREPO': 1,
        #         'NofAlus': 3,
        #         'NofLsus': 3,
        #         'NofFpus': 1,
        #         'NofAluBufEntries': 4,
        #         'NofLsuBufEntries': 4,
        #         'NofFpuBufEntries': 4,
        #         'AluNofRss': 1,
        #         'LsuNofRss': 3,
        #         'FpuNofRss': 1,
        #         'ICacheFetchDataWidth': 128,
        #         'NofPhysGpr': 40,
        #         'NofPhysFpr': 42,
        #         'NofRobEntries': 1,
        #         'UseFreeList': 0,
        #     }
        # },
        # {
        #     'design':   'schnova_synth',
        #     'name':     'LA-PW8',
        #     'hdl_params': {
        #         'XFREPI': 1,
        #         'XFREPO': 1,
        #         'NofAlus': 3,
        #         'NofLsus': 3,
        #         'NofFpus': 1,
        #         'NofAluBufEntries': 8,
        #         'NofLsuBufEntries': 8,
        #         'NofFpuBufEntries': 8,
        #         'AluNofRss': 1,
        #         'LsuNofRss': 8,
        #         'FpuNofRss': 1,
        #         'ICacheFetchDataWidth': 256,
        #         'NofPhysGpr': 48,
        #         'NofPhysFpr': 54,
        #         'NofRobEntries': 1,
        #         'UseFreeList': 0,
        #     }
        # },
        # {
        #     'design': 'schnizo_synth',
        #     'name': 'Schnizo-LA',
        #     'hdl_params': {
        #         'Xfrep': 1,
        #         'NofAlus': 3,
        #         'NofLsus': 3,
        #         'NofFpus': 1,
        #         'AluNofRss': 4,
        #         'LsuNofRss': 4,
        #         'FpuNofRss': 4,
        #         'AluNofConstants': 4,
        #         'LsuNofConstants': 4,
        #         'FpuNofConstants': 4,
        #     }
        # },
        # {
        #     'design': 'schnizo_synth',
        #     'name': 'Schnizo-GP-L',
        #     'hdl_params': {
        #         'Xfrep': 1,
        #         'NofAlus': 3,
        #         'NofLsus': 3,
        #         'NofFpus': 1,
        #         'AluNofRss': 32,
        #         'LsuNofRss': 32,
        #         'FpuNofRss': 64,
        #         'AluNofConstants': 16,
        #         'LsuNofConstants': 64,
        #         'FpuNofConstants': 32,
        #     }
        # },
    ]

    # Experiments are ungrouped unless specified otherwise
    for experiment in experiments:
        experiment.setdefault('grouped', False)
        if experiment['grouped']:
            experiment['keep_hier'] = schnova_keep_hier(experiment['hdl_params'])

    if designs is not None:
        experiments = [experiment for experiment in experiments if experiment['name'] in designs]
    return experiments


def results(dir=None, grouped=False):
    manager = ExperimentManager(gen_experiments(), dir=dir, parse_args=False)
    df = manager.get_results()
    df = df[df['grouping'] == ('grouped' if grouped else 'ungrouped')].drop(columns='grouping')
    df = df.set_index('name')
    df['synth_results'] = df['synth_results'].str[FINAL_SYNTH_STAGE]
    return df


def main():
    parser = ExperimentManager.parser()
    parser.add_argument('--designs', nargs='+')
    args = parser.parse_args()
    experiments = gen_experiments(designs=args.designs)
    manager = ExperimentManager(experiments=experiments, args=args, parse_args=False)

    manager.run()


if __name__ == '__main__':
    main()
