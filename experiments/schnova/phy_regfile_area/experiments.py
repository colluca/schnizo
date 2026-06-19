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
    # Define axes
    num_write_ports_axis = [1]
    num_op_ifs_axis = [4, 8, 12]
    num_regs_axis = [48, 64, 80, 96, 112]

    # Generate list of experiments
    experiments = []

    for num_write_ports in num_write_ports_axis:
        for num_op_ifs in num_op_ifs_axis:
            for num_regs in num_regs_axis:
                experiments.append({
                            'design': 'schnova_phys_regfile_synth',
                            'hdl_params': {
                                'DataWidth': 32,
                                'NrReadPorts': 2,
                                'NrWritePorts': num_write_ports,
                                'NofOperandIfs': num_op_ifs,
                                'ZeroRegZero': 1,
                                'PhysAddrWidth': 7,
                                'NumRegs': num_regs
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
