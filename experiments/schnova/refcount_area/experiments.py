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

    num_buf_entries_axis = [2, 4, 8, 16, 32]
    num_regs_axis = [32, 48, 64, 80]
    num_fus_axis = [1, 2, 3, 4]
    num_rss_axis = [1, 2, 4, 8, 16, 32]
    pipewidth_axis = [1, 2, 4, 8]

    for num_buf_entries in num_buf_entries_axis:
        experiments.append({
                                'design': 'schnova_refcount_synth',
                                'hdl_params': {
                                    'PipeWidth':        1,
                                    'NofPhysGpr':       64,
                                    'NofPhysFpr':       64,
                                    'NofAlus':          1,
                                    'AluNofRss':        1,
                                    'NofLsus':          1,
                                    'LsuNofRss':        1,
                                    'NofFpus':          1,
                                    'FpuNofRss':        1,
                                    'NofAluBufEntries': num_buf_entries,
                                    'NofLsuBufEntries': 1,
                                    'NofFpuBufEntries': 1
                                }
                            })
        experiments.append({
                                'design': 'schnova_refcount_synth',
                                'hdl_params': {
                                    'PipeWidth':        1,
                                    'NofPhysGpr':       64,
                                    'NofPhysFpr':       64,
                                    'NofAlus':          1,
                                    'AluNofRss':        1,
                                    'NofLsus':          1,
                                    'LsuNofRss':        1,
                                    'NofFpus':          1,
                                    'FpuNofRss':        1,
                                    'NofAluBufEntries': 1,
                                    'NofLsuBufEntries': num_buf_entries,
                                    'NofFpuBufEntries': 1
                                }
                            })
        experiments.append({
                                'design': 'schnova_refcount_synth',
                                'hdl_params': {
                                    'PipeWidth':        1,
                                    'NofPhysGpr':       64,
                                    'NofPhysFpr':       64,
                                    'NofAlus':          1,
                                    'AluNofRss':        1,
                                    'NofLsus':          1,
                                    'LsuNofRss':        1,
                                    'NofFpus':          1,
                                    'FpuNofRss':        1,
                                    'NofAluBufEntries': 1,
                                    'NofLsuBufEntries': 1,
                                    'NofFpuBufEntries': num_buf_entries,
                                }
                            })
    for num_regs in num_regs_axis:
        experiments.append({
                                'design': 'schnova_refcount_synth',
                                'hdl_params': {
                                    'PipeWidth':        1,
                                    'NofPhysGpr':       num_regs,
                                    'NofPhysFpr':       1,
                                    'NofAlus':          1,
                                    'AluNofRss':        1,
                                    'NofLsus':          1,
                                    'LsuNofRss':        1,
                                    'NofFpus':          1,
                                    'FpuNofRss':        1,
                                    'NofAluBufEntries': 1,
                                    'NofLsuBufEntries': 1,
                                    'NofFpuBufEntries': 1,
                                }
                            })
        experiments.append({
                                'design': 'schnova_refcount_synth',
                                'hdl_params': {
                                    'PipeWidth':        1,
                                    'NofPhysGpr':       1,
                                    'NofPhysFpr':       num_regs,
                                    'NofAlus':          1,
                                    'AluNofRss':        1,
                                    'NofLsus':          1,
                                    'LsuNofRss':        1,
                                    'NofFpus':          1,
                                    'FpuNofRss':        1,
                                    'NofAluBufEntries': 1,
                                    'NofLsuBufEntries': 1,
                                    'NofFpuBufEntries': 1,
                                }
                            })
    
    for num_fus in num_fus_axis:
        experiments.append({
                                'design': 'schnova_refcount_synth',
                                'hdl_params': {
                                    'PipeWidth':        1,
                                    'NofPhysGpr':       64,
                                    'NofPhysFpr':       64,
                                    'NofAlus':          num_fus,
                                    'AluNofRss':        1,
                                    'NofLsus':          1,
                                    'LsuNofRss':        1,
                                    'NofFpus':          1,
                                    'FpuNofRss':        1,
                                    'NofAluBufEntries': 1,
                                    'NofLsuBufEntries': 1,
                                    'NofFpuBufEntries': 1,
                                }
                            })
        experiments.append({
                                'design': 'schnova_refcount_synth',
                                'hdl_params': {
                                    'PipeWidth':        1,
                                    'NofPhysGpr':       64,
                                    'NofPhysFpr':       64,
                                    'NofAlus':          1,
                                    'AluNofRss':        1,
                                    'NofLsus':          num_fus,
                                    'LsuNofRss':        1,
                                    'NofFpus':          1,
                                    'FpuNofRss':        1,
                                    'NofAluBufEntries': 1,
                                    'NofLsuBufEntries': 1,
                                    'NofFpuBufEntries': 1,
                                }
                            })
        experiments.append({
                                'design': 'schnova_refcount_synth',
                                'hdl_params': {
                                    'PipeWidth':        1,
                                    'NofPhysGpr':       64,
                                    'NofPhysFpr':       64,
                                    'NofAlus':          1,
                                    'AluNofRss':        1,
                                    'NofLsus':          1,
                                    'LsuNofRss':        1,
                                    'NofFpus':          num_fus,
                                    'FpuNofRss':        1,
                                    'NofAluBufEntries': 1,
                                    'NofLsuBufEntries': 1,
                                    'NofFpuBufEntries': 1,
                                }
                            })
    for num_rss in num_rss_axis:
        experiments.append({
                                'design': 'schnova_refcount_synth',
                                'hdl_params': {
                                    'PipeWidth':        1,
                                    'NofPhysGpr':       64,
                                    'NofPhysFpr':       64,
                                    'NofAlus':          1,
                                    'AluNofRss':        num_rss,
                                    'NofLsus':          1,
                                    'LsuNofRss':        1,
                                    'NofFpus':          1,
                                    'FpuNofRss':        1,
                                    'NofAluBufEntries': 1,
                                    'NofLsuBufEntries': 1,
                                    'NofFpuBufEntries': 1,
                                }
                            })
        experiments.append({
                                'design': 'schnova_refcount_synth',
                                'hdl_params': {
                                    'PipeWidth':        1,
                                    'NofPhysGpr':       64,
                                    'NofPhysFpr':       64,
                                    'NofAlus':          1,
                                    'AluNofRss':        1,
                                    'NofLsus':          1,
                                    'LsuNofRss':        num_rss,
                                    'NofFpus':          1,
                                    'FpuNofRss':        1,
                                    'NofAluBufEntries': 1,
                                    'NofLsuBufEntries': 1,
                                    'NofFpuBufEntries': 1,
                                }
                            })
        experiments.append({
                                'design': 'schnova_refcount_synth',
                                'hdl_params': {
                                    'PipeWidth':        1,
                                    'NofPhysGpr':       64,
                                    'NofPhysFpr':       64,
                                    'NofAlus':          1,
                                    'AluNofRss':        1,
                                    'NofLsus':          1,
                                    'LsuNofRss':        1,
                                    'NofFpus':          1,
                                    'FpuNofRss':        num_rss,
                                    'NofAluBufEntries': 1,
                                    'NofLsuBufEntries': 1,
                                    'NofFpuBufEntries': 1,
                                }
                            })
    for pipewidth in pipewidth_axis:
        experiments.append({
                                'design': 'schnova_refcount_synth',
                                'hdl_params': {
                                    'PipeWidth':        pipewidth,
                                    'NofPhysGpr':       64,
                                    'NofPhysFpr':       64,
                                    'NofAlus':          1,
                                    'AluNofRss':        1,
                                    'NofLsus':          1,
                                    'LsuNofRss':        1,
                                    'NofFpus':          1,
                                    'FpuNofRss':        1,
                                    'NofAluBufEntries': 1,
                                    'NofLsuBufEntries': 1,
                                    'NofFpuBufEntries': 1,
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
