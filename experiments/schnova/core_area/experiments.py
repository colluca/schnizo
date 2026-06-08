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
            'name': 'schnizo_s',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
                'AluNofRss': 1,
                'LsuNofRss': 1,
                'FpuNofRss': 1,
                'AluNofConstants': 1,
                'LsuNofConstants': 1,
                'FpuNofConstants': 1,
            }
        },
        {'design': 'schnova_synth',
                    'name': 'gp_sv1_s',
                    'hdl_params': {
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
                        'NofPhysGpr': 33,
	                    'NofPhysFpr': 33,
                        'NofRobEntries': 1,
                        'UseFreeList': 0,
                        }
        },
        {'design': 'schnova_synth',
                       'name': 'gp_sv2_rob',
                       'hdl_params': {
                           'NofAlus': 2,
                           'NofLsus': 2,
                           'NofFpus': 1,
                           'NofAluBufEntries': 14,
                           'NofLsuBufEntries': 14,
                           'NofFpuBufEntries': 24,
                           'AluNofRss': 1,
                           'LsuNofRss': 1,
                           'FpuNofRss': 1,
                           'ICacheFetchDataWidth': 64,
                           'NofPhysGpr': 92,
	                       'NofPhysFpr': 82,
                           'NofRobEntries': 64,
                           'UseFreeList': 1,
                           }
        },
        {'design': 'schnova_synth',
                       'name': 'gp_sv2_rc',
                       'hdl_params': {
                           'NofAlus': 2,
                           'NofLsus': 2,
                           'NofFpus': 1,
                           'NofAluBufEntries': 14,
                           'NofLsuBufEntries': 14,
                           'NofFpuBufEntries': 24,
                           'AluNofRss': 1,
                           'LsuNofRss': 1,
                           'FpuNofRss': 1,
                           'ICacheFetchDataWidth': 64,
                           'NofPhysGpr': 48,
	                       'NofPhysFpr': 52,
                           'NofRobEntries': 1,
                           'UseFreeList': 0,
                           }
        },
        {'design': 'schnova_synth',
                       'name': 'gp_sv2_rob_bal',
                       'hdl_params': {
                           'NofAlus': 2,
                           'NofLsus': 2,
                           'NofFpus': 1,
                           'NofAluBufEntries': 4,
                           'NofLsuBufEntries': 6,
                           'NofFpuBufEntries': 8,
                           'AluNofRss': 1,
                           'LsuNofRss': 1,
                           'FpuNofRss': 1,
                           'ICacheFetchDataWidth': 32,
                           'NofPhysGpr': 48,
	                       'NofPhysFpr': 54,
                           'NofRobEntries': 32,
                           'UseFreeList': 1,
                           }
        },
        {'design': 'schnova_synth',
                       'name': 'gp_sv2_rc_bal',
                       'hdl_params': {
                           'NofAlus': 2,
                           'NofLsus': 2,
                           'NofFpus': 1,
                           'NofAluBufEntries': 4,
                           'NofLsuBufEntries': 6,
                           'NofFpuBufEntries': 8,
                           'AluNofRss': 1,
                           'LsuNofRss': 1,
                           'FpuNofRss': 1,
                           'ICacheFetchDataWidth': 64,
                           'NofPhysGpr': 38,
	                       'NofPhysFpr': 38,
                           'NofRobEntries': 1,
                           'UseFreeList': 0,
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
