#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments import experiment_utils as eu

FINAL_SYNTH_STAGE = '9'


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        return experiment['hdl_params']


#def gen_experiments():
#    # Define axes
#    num_slots_axis = [1, 2, 4, 8, 16, 32, 64]
#    num_operands_axis = [3]
#
#    # Generate list of experiments
#    experiments = []
#    for num_slots in num_slots_axis:
#            for num_operands in num_operands_axis:
#                experiments.append({
#                    'design': 'schnova_res_stat_synth',
#                    'name': f'{num_slots}slots_{num_operands}operands',
#                    'hdl_params': {
#                        'NofRss': num_slots,
#                        'NofOperands': num_operands
#                    }
#                })
#    return experiments

def gen_experiments(designs=None):
    # Define axes
    num_write_ports_axis = [1, 2, 4, 8]
    num_rs_axis = [3, 4, 5, 6, 7]
    addr_width_axis = [6, 7, 8]

    # Generate list of experiments
    experiments = []

    for addr_width in addr_width_axis:
        for num_rs in num_rs_axis:
            for num_write_ports in num_write_ports_axis:
                # Assuming every reservation stataion has 3 operands it needs to read (not true for ALU)
                num_op_read_ports = num_rs*3
                experiments.append({
                            'design': 'schnova_phys_regfile_synth',
                            'name': f'sv{num_write_ports}_rs{num_rs}_w{addr_width}_gpr',
                            'hdl_params': {
                                'DataWidth': 32,
                                'NrReadPorts': 2,
                                'NrWritePorts': num_write_ports,
                                'NofOperandIfs': num_op_read_ports,
                                'ZeroRegZero': 1,
                                'AddrWidth': addr_width
                            }
                        })
                
                experiments.append({
                            'design': 'schnova_phys_regfile_synth',
                            'name': f'sv{num_write_ports}_rs{num_rs}_w{addr_width}_fpr',
                            'hdl_params': {
                                'DataWidth': 64,
                                'NrReadPorts': 3,
                                'NrWritePorts': num_write_ports,
                                'NofOperandIfs': num_op_read_ports,
                                'ZeroRegZero': 0,
                                'AddrWidth': addr_width
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
