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
        { 'design': 'schnova_synth', 
                       'name': 'gp_sv1', 
                       'hdl_params': { 
                           'NofAlus': 3, 
                           'NofLsus': 3, 
                           'NofFpus': 1, 
                           'AluNofRss': 4, 
                           'LsuNofRss': 4, 
                           'FpuNofRss': 4, 
                           'ICacheFetchDataWidth': 32, 
                           'PhysRegAddrSize': 6, 
                           'NofRobEntries': 16, 
                           } 
        },
        { 'design': 'schnova_synth', 
                       'name': 'gp_sv2', 
                       'hdl_params': { 
                           'NofAlus': 3, 
                           'NofLsus': 3, 
                           'NofFpus': 1, 
                           'AluNofRss': 8, 
                           'LsuNofRss': 8, 
                           'FpuNofRss': 8, 
                           'ICacheFetchDataWidth': 64, 
                           'PhysRegAddrSize': 6, 
                           'NofRobEntries': 32, 
                           } 
        },
        { 'design': 'schnova_synth', 
                       'name': 'gp_sv4', 
                       'hdl_params': { 
                           'NofAlus': 3, 
                           'NofLsus': 3, 
                           'NofFpus': 1, 
                           'AluNofRss': 16, 
                           'LsuNofRss': 16, 
                           'FpuNofRss': 16, 
                           'ICacheFetchDataWidth': 128, 
                           'PhysRegAddrSize': 6, 
                           'NofRobEntries': 64, 
                           } 
        },
        { 'design': 'schnova_synth', 
                       'name': 'gp_sv8', 
                       'hdl_params': { 
                           'NofAlus': 3, 
                           'NofLsus': 3, 
                           'NofFpus': 1, 
                           'AluNofRss': 32, 
                           'LsuNofRss': 32, 
                           'FpuNofRss': 32, 
                           'ICacheFetchDataWidth': 256, 
                           'PhysRegAddrSize': 6, 
                           'NofRobEntries': 64, 
                           } 
        },
        # GP-L
        #{
        #    'design': 'schnizo_synth',
        #    'name': 'superscalar_3x32_3x32_1x64',
        #    'hdl_params': {
        #        'Xfrep': 1,
        #        'NofAlus': 3,
        #        'NofLsus': 3,
        #        'NofFpus': 1,
        #        'AluNofRss': 32,
        #        'LsuNofRss': 32,
        #        'FpuNofRss': 64,
        #        'AluNofConstants': 16,
        #        'LsuNofConstants': 64,
        #        'FpuNofConstants': 32,
        #    }
        #},
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
