#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import matplotlib.pyplot as plt
from . import experiments
from .experiments import NUM_RS

GE = 0.121


def to_ge(area_um2):
    return area_um2 / GE


def to_kge(area_um2):
    return to_ge(area_um2) / 1e3


def results(dir=None):
    df = experiments.results(dir=dir)

    df['StdCellArea'] = df['synth_results'].str['qor_summary'].str['StdCellArea']
    df['StdCellArea'] = df['StdCellArea'].map(to_kge).round(1)
    df['hierarchy_details'] = df['synth_results'].str['hierarchy_details']
    df['CombArea'] = df['hierarchy_details'].map(lambda x: to_kge(x.tree.get_attr('CombArea')))
    df['SeqArea'] = df['hierarchy_details'].map(lambda x: to_kge(x.tree.get_attr('SeqArea')))
    df['CombArea'] = df['CombArea'].round(0).astype('int')
    df['SeqArea'] = df['SeqArea'].round(0).astype('int')
    df['1BitEqSeq'] = (df['synth_results'].str['multibit'].str['1BitEqSeq']).astype('int')
    df['GE/bit'] = (1e3 * df['SeqArea'] / df['1BitEqSeq']).round(1)

    df.drop(columns=['hierarchy_details'], inplace=True)
    df.drop(columns=['synth_results'], inplace=True)

    return df


def plot_req_xbar(dir=None, show=False, hide_x_axis=False):
    df = results(dir=dir)
    req = df[(df['name'] == 'req_xbar') & (df['num_slots'] > NUM_RS)]

    pivot = req.groupby('num_slots')['StdCellArea'].mean()

    fig, ax = plt.subplots()
    x = range(len(pivot))
    ax.bar(x, pivot.values, zorder=3)
    ax.set_ylabel('Area [kGE]')
    ax.set_xticks(x)
    if hide_x_axis:
        ax.tick_params(axis='x', which='both', bottom=False, labelbottom=False)
    else:
        ax.set_xlabel('Number of RSEs')
        ax.set_xticklabels(pivot.index // NUM_RS)
    ax.grid(True, axis='y')
    fig.tight_layout()

    if show:
        plt.show()

    return pivot


def plot_rsp_xbar(dir=None, show=False):
    df = results(dir=dir)
    df = df[(df['name'] == 'rsp_xbar') & (df['num_slots'] > NUM_RS)]

    pivot = df.pivot_table(index='num_slots', columns='num_rsp_ports', values='StdCellArea')
    pivot.columns = [f'{int(p)} prod. port{"" if int(p) == 1 else "s"}' for p in pivot.columns]

    fig, ax = plt.subplots()
    pivot.plot(kind='bar', ax=ax, zorder=3)
    ax.set_xlabel('Number of RSEs')
    ax.set_ylabel('Area [kGE]')
    ax.set_xticklabels(pivot.index // NUM_RS, rotation=0)
    ax.legend()
    ax.grid(True, axis='y')
    fig.tight_layout()

    if show:
        plt.show()

    return pivot


def main():
    print(results())


if __name__ == '__main__':
    main()
