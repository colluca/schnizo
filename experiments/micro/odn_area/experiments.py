#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments import experiment_utils as eu


FINAL_SYNTH_STAGE = '9'

# Experiment constants
NUM_OPERANDS_PER_RS = 3
NUM_SLOTS_PER_RS = 4


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        keys = ['name', 'num_rs', 'num_rsp_ports']
        if experiment['design'] == 'schnizo_req_xbar_synth':
            keys.append('num_slots')
        return eu.derive_axes_from_keys(experiment, keys=keys)


def gen_experiments():
    # Define axes
    num_rs_axis = [3, 4, 5, 6, 7]
    num_slots_axis = [12, 24, 48, 96, 192]
    num_rsp_ports_axis = [1, 2, 3]

    # Generate list of experiments
    experiments = []
    for num_rs in num_rs_axis:
        if num_rs == 3:
            num_slots_axis_mod = num_slots_axis
        else:
            num_slots_axis_mod = [num_rs * NUM_SLOTS_PER_RS]
        for num_slots in num_slots_axis_mod:
            for num_rsp_ports in num_rsp_ports_axis:
                experiments.append(
                    {
                        'design': 'schnizo_req_xbar_synth',
                        'name': 'req_xbar',
                        'num_rs': num_rs,
                        'num_rsp_ports': num_rsp_ports,
                        'num_slots': num_slots,
                        'hdl_params': {
                            'NofOperandReqs': NUM_OPERANDS_PER_RS * num_rs,
                            'NofRs': num_rs,
                            'NofRssPerRs': num_slots // num_rs,
                            'NofResRspIfsPerRs': num_rsp_ports,
                        }
                    }
                )
    for num_rs in num_rs_axis:
        for num_rsp_ports in num_rsp_ports_axis:
            experiments.append(
                {
                    'design': 'schnizo_rsp_xbar_synth',
                    'name': 'rsp_xbar',
                    'num_rs': num_rs,
                    'num_rsp_ports': num_rsp_ports,
                    'hdl_params': {
                        'NumInp': num_rsp_ports * num_rs,
                        'NumOut': NUM_OPERANDS_PER_RS * num_rs,
                    }
                }
            )
    return experiments


def results(dir=None):
    manager = ExperimentManager(gen_experiments(), dir=dir, parse_args=False)
    df = manager.get_results()
    df['synth_results'] = df['synth_results'].str[FINAL_SYNTH_STAGE]
    return df


def main():
    experiments = gen_experiments()
    manager = ExperimentManager(experiments=experiments)

    manager.run()


if __name__ == '__main__':
    main()
