#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments import experiment_utils as eu

EARLY_SYNTH_STAGE = '7'
FINAL_SYNTH_STAGE = '9'


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        return eu.derive_axes_from_keys(experiment, keys=['name'])


def gen_experiments(designs=None):
    # Generate list of experiments
    # IMPORTANT: HDL parameters should be listed in the same order they appear in the RTL
    experiments = [
        {
            'design': 'schnizo_synth',
            'name': 'Schnizo',
            'hdl_params': {
                'Xfrep': 0,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 0,
                'MulInAlu0': 1,
            }
        },
        {
            'design': 'schnizo_synth',
            'name': 'Schnizo-FP',
            'hdl_params': {
                'Xfrep': 0,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
            }
        },
        {
            'design':   'schnova_synth',
            'name':     'Schnova',
            'hdl_params': {
                'XFREPI': 0,
                'XFREPO': 0,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 0,
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
        {
            'design':   'schnova_synth',
            'name':     'Schnova-FP',
            'hdl_params': {
                'XFREPI': 0,
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
        {
            'design':   'schnova_synth',
            'name':     'Schnova-ZOL',
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
        {
            'design':   'schnova_synth',
            'name':     'GP-SV1',
            'hdl_params': {
                'XFREPI': 1,
                'XFREPO': 1,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
                'NofAluBufEntries': 4,
                'NofLsuBufEntries': 2,
                'NofFpuBufEntries': 6,
                'AluNofRss': 1,
                'LsuNofRss': 1,
                'FpuNofRss': 1,
                'ICacheFetchDataWidth': 32,
                'NofPhysGpr': 38,
                'NofPhysFpr': 38,
                'NofRobEntries': 1,
                'UseFreeList': 0,
            }
        },
        {
            'design':   'schnova_synth',
            'name':     'GP-SV2',
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
        {
            'design':   'schnova_synth',
            'name':     'GP-SV4',
            'hdl_params': {
                'XFREPI': 1,
                'XFREPO': 1,
                'NofAlus': 3,
                'NofLsus': 3,
                'NofFpus': 1,
                'NofAluBufEntries': 16,
                'NofLsuBufEntries': 12,
                'NofFpuBufEntries': 30,
                'AluNofRss': 1,
                'LsuNofRss': 4,
                'FpuNofRss': 1,
                'ICacheFetchDataWidth': 128,
                'NofPhysGpr': 52,
                'NofPhysFpr': 56,
                'NofRobEntries': 1,
                'UseFreeList': 0,
            }
        },
        {
            'design':   'schnova_synth',
            'name':     'GP-SV8',
            'hdl_params': {
                'XFREPI': 1,
                'XFREPO': 1,
                'NofAlus': 3,
                'NofLsus': 3,
                'NofFpus': 1,
                'NofAluBufEntries': 16,
                'NofLsuBufEntries': 8,
                'NofFpuBufEntries': 28,
                'AluNofRss': 1,
                'LsuNofRss': 8,
                'FpuNofRss': 1,
                'ICacheFetchDataWidth': 256,
                'NofPhysGpr': 52,
                'NofPhysFpr': 54,
                'NofRobEntries': 1,
                'UseFreeList': 0,
            }
        },
        {
            'design':   'schnova_synth',
            'name':     'GP-SV1-Bal',
            'hdl_params': {
                'XFREPI': 1,
                'XFREPO': 1,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
                'NofAluBufEntries': 2,
                'NofLsuBufEntries': 2,
                'NofFpuBufEntries': 4,
                'AluNofRss': 1,
                'LsuNofRss': 1,
                'FpuNofRss': 1,
                'ICacheFetchDataWidth': 32,
                'NofPhysGpr': 34,
                'NofPhysFpr': 38,
                'NofRobEntries': 1,
                'UseFreeList': 0,
            }
        },
        {
            'design':   'schnova_synth',
            'name':     'GP-SV2-Bal',
            'hdl_params': {
                'XFREPI': 1,
                'XFREPO': 1,
                'NofAlus': 2,
                'NofLsus': 2,
                'NofFpus': 1,
                'NofAluBufEntries': 10,
                'NofLsuBufEntries': 6,
                'NofFpuBufEntries': 8,
                'AluNofRss': 1,
                'LsuNofRss': 1,
                'FpuNofRss': 1,
                'ICacheFetchDataWidth': 64,
                'NofPhysGpr': 44,
                'NofPhysFpr': 40,
                'NofRobEntries': 1,
                'UseFreeList': 0,
            }
        },
        {
            'design':   'schnova_synth',
            'name':     'GP-SV1-rob',
            'hdl_params': {
                'XFREPI': 1,
                'XFREPO': 1,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
                'NofAluBufEntries': 4,
                'NofLsuBufEntries': 2,
                'NofFpuBufEntries': 6,
                'AluNofRss': 1,
                'LsuNofRss': 1,
                'FpuNofRss': 1,
                'ICacheFetchDataWidth': 32,
                'NofPhysGpr': 68,
                'NofPhysFpr': 116,
                'NofRobEntries': 128,
                'UseFreeList': 1,
            }
        },
        {
            'design':   'schnova_synth',
            'name':     'GP-SV2-rob',
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
                'NofPhysGpr': 92,
                'NofPhysFpr': 80,
                'NofRobEntries': 64,
                'UseFreeList': 1,
            }
        },
        {
            'design':   'schnova_synth',
            'name':     'GP-SV4-rob',
            'hdl_params': {
                'XFREPI': 1,
                'XFREPO': 1,
                'NofAlus': 3,
                'NofLsus': 3,
                'NofFpus': 1,
                'NofAluBufEntries': 16,
                'NofLsuBufEntries': 12,
                'NofFpuBufEntries': 30,
                'AluNofRss': 1,
                'LsuNofRss': 4,
                'FpuNofRss': 1,
                'ICacheFetchDataWidth': 128,
                'NofPhysGpr': 114,
                'NofPhysFpr': 68,
                'NofRobEntries': 128,
                'UseFreeList': 1,
            }
        },
        {
            'design':   'schnova_synth',
            'name':     'GP-SV8-rob',
            'hdl_params': {
                'XFREPI': 1,
                'XFREPO': 1,
                'NofAlus': 3,
                'NofLsus': 3,
                'NofFpus': 1,
                'NofAluBufEntries': 16,
                'NofLsuBufEntries': 8,
                'NofFpuBufEntries': 28,
                'AluNofRss': 1,
                'LsuNofRss': 8,
                'FpuNofRss': 1,
                'ICacheFetchDataWidth': 256,
                'NofPhysGpr': 114,
                'NofPhysFpr': 66,
                'NofRobEntries': 128,
                'UseFreeList': 1,
            }
        },
    ]

    if designs is not None:
        experiments = [experiment for experiment in experiments if experiment['name'] in designs]
    return experiments


def results(dir=None):
    manager = ExperimentManager(gen_experiments(), dir=dir, parse_args=False)
    df = manager.get_results()
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
