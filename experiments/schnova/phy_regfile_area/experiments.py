#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments import experiment_utils as eu

FINAL_SYNTH_STAGE = '9'


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        return experiment['hdl_params']


def gen_experiments(designs=None):

    experiments = []

    num_regs_axis = [48, 64, 80, 96, 112]
    num_fus_axis = [1, 2, 3, 4]
    pipewidth_axis = [1, 2, 4, 8]

    for num_regs in num_regs_axis:
        for num_fus in num_fus_axis:
            experiments.append({
                                    'design': 'schnova_phys_regfile_synth',
                                    'hdl_params': {
                                        'NumRegs':   num_regs,
                                        'DataWidth': 32,
                                        'IsGpr':     1,
                                        'NofAlus':   num_fus,
                                        'NofLsus':   1,
                                        'NofFpus':   1,
                                        'PipeWidth': 1,
                                    }
                                })

            experiments.append({
                                    'design': 'schnova_phys_regfile_synth',
                                    'hdl_params': {
                                        'NumRegs':   num_regs,
                                        'DataWidth': 64,
                                        'IsGpr':     0,
                                        'NofAlus':   num_fus,
                                        'NofLsus':   1,
                                        'NofFpus':   1,
                                        'PipeWidth': 1,
                                    }
                                })

            experiments.append({
                                    'design': 'schnova_phys_regfile_synth',
                                    'hdl_params': {
                                        'NumRegs':   num_regs,
                                        'DataWidth': 32,
                                        'IsGpr':     1,
                                        'NofAlus':   1,
                                        'NofLsus':   num_fus,
                                        'NofFpus':   1,
                                        'PipeWidth': 1,
                                    }
                                })

            experiments.append({
                                    'design': 'schnova_phys_regfile_synth',
                                    'hdl_params': {
                                        'NumRegs':   num_regs,
                                        'DataWidth': 64,
                                        'IsGpr':     0,
                                        'NofAlus':   1,
                                        'NofLsus':   num_fus,
                                        'NofFpus':   1,
                                        'PipeWidth': 1,
                                    }
                                })

            experiments.append({
                                    'design': 'schnova_phys_regfile_synth',
                                    'hdl_params': {
                                        'NumRegs':   num_regs,
                                        'DataWidth': 32,
                                        'IsGpr':     1,
                                        'NofAlus':   1,
                                        'NofLsus':   1,
                                        'NofFpus':   num_fus,
                                        'PipeWidth': 1,
                                    }
                                })

            experiments.append({
                                    'design': 'schnova_phys_regfile_synth',
                                    'hdl_params': {
                                        'NumRegs':   num_regs,
                                        'DataWidth': 64,
                                        'IsGpr':     0,
                                        'NofAlus':   1,
                                        'NofLsus':   1,
                                        'NofFpus':   num_fus,
                                        'PipeWidth': 1,
                                    }
                                })

        for pipewidth in pipewidth_axis:
            experiments.append({
                                    'design': 'schnova_phys_regfile_synth',
                                    'hdl_params': {
                                        'NumRegs':   num_regs,
                                        'DataWidth': 32,
                                        'IsGpr':     1,
                                        'NofAlus':   1,
                                        'NofLsus':   1,
                                        'NofFpus':   1,
                                        'PipeWidth': pipewidth,
                                    }
                                })

            experiments.append({
                            'design': 'schnova_phys_regfile_synth',
                            'hdl_params': {
                                'NumRegs':   num_regs,
                                'DataWidth': 64,
                                'IsGpr':     0,
                                'NofAlus':   1,
                                'NofLsus':   1,
                                'NofFpus':   1,
                                'PipeWidth': pipewidth,
                            }
                        })

    if designs is not None:
        experiments = [experiment for experiment in experiments if experiment['name'] in designs]
    return experiments


def results(dir=None):
    manager = ExperimentManager(gen_experiments(), dir=dir, parse_args=False)
    df = manager.get_results()
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
