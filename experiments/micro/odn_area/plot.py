#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import matplotlib.pyplot as plt
from . import experiments

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


def plot_req_xbar_slots(dir=None, show=False, hide_x_axis=False):
    df = results(dir=dir)
    num_rs = 3
    num_rsp_ports = 3
    req = df[(df['name'] == 'req_xbar') & (df['num_rs'] == num_rs) &
             (df['num_rsp_ports'] == num_rsp_ports)]

    pivot = req.groupby('num_slots')['StdCellArea'].mean()

    fig, ax = plt.subplots()
    x = range(len(pivot))
    ax.bar(x, pivot.values, zorder=3)
    ax.set_ylabel('Area [kGE]')
    ax.set_xticks(x)
    if hide_x_axis:
        ax.tick_params(axis='x', which='both', bottom=False, labelbottom=False)
    else:
        ax.set_xlabel('Number of RSEs per RS')
        ax.set_xticklabels([int(v) for v in pivot.index // num_rs])
    ax.grid(True, axis='y')
    fig.tight_layout()

    if show:
        plt.show()

    return pivot


def plot_req_xbar(dir=None, show=False, hide_x_axis=False):
    df = results(dir=dir)
    req = df[df['name'] == 'req_xbar']
    req = req[req['num_slots'] == req['num_rs'] * experiments.NUM_SLOTS_PER_RS]

    pivot = req.pivot_table(index='num_rs', columns='num_rsp_ports', values='StdCellArea')
    pivot.columns = [f'{int(p)} port{"" if int(p) == 1 else "s"}' for p in pivot.columns]

    fig, ax = plt.subplots()
    pivot.plot(kind='bar', ax=ax, zorder=3)
    ax.set_ylabel('Area [kGE]')
    if hide_x_axis:
        ax.tick_params(axis='x', which='both', bottom=False, labelbottom=False)
    else:
        ax.set_xlabel('Number of RSs')
        ax.set_xticklabels([int(v) for v in pivot.index], rotation=0)
    ax.legend(ncol=3)
    ax.grid(True, axis='y')
    fig.tight_layout()

    if show:
        plt.show()

    return pivot


def plot_rsp_xbar(dir=None, show=False):
    df = results(dir=dir)
    df = df[df['name'] == 'rsp_xbar']

    pivot = df.pivot_table(index='num_rs', columns='num_rsp_ports', values='StdCellArea')
    pivot.columns = [f'{int(p)} port{"" if int(p) == 1 else "s"}' for p in pivot.columns]

    fig, ax = plt.subplots()
    pivot.plot(kind='bar', ax=ax, zorder=3)
    ax.set_xlabel('Number of RSs')
    ax.set_ylabel('Area [kGE]')
    ax.set_xticklabels([int(v) for v in pivot.index], rotation=0)
    ax.legend(ncol=3)
    ax.grid(True, axis='y')
    fig.tight_layout()

    if show:
        plt.show()

    return pivot


def linear_regression(dir=None):
    """Fit linear models (area = slope * n_rse + intercept) for req and rsp xbars.

    Returns a dict with:
      'req_xbar': {num_ports: {'slope', 'intercept', 'r2'}, ...}  (area vs num_rs)
      'req_xbar_slots': {num_ports: {'slope', 'intercept', 'r2'}, ...}
        (area vs num_slots, at num_rs=3)
      'rsp_xbar': {num_ports: {'slope', 'intercept', 'r2'}, ...}
    """
    from scipy.stats import linregress
    df = results(dir=dir)
    print(df)

    fits = {}

    req = df[df['name'] == 'req_xbar']
    req = req[req['num_slots'] == req['num_rs'] * experiments.NUM_SLOTS_PER_RS]
    pivot = req.pivot_table(index='num_rs', columns='num_rsp_ports', values='StdCellArea')
    print(pivot)
    x = pivot.index.values
    fits['req_xbar'] = {}
    for ports in pivot.columns:
        slope, intercept, r, _, _ = linregress(x, pivot[ports].values)
        fits['req_xbar'][int(ports)] = {'slope': slope, 'intercept': intercept, 'r2': r**2}

    # Slots sweep is only available for num_rs=3
    req_slots = df[(df['name'] == 'req_xbar') & (df['num_rs'] == 3)]
    pivot = req_slots.pivot_table(index='num_slots', columns='num_rsp_ports', values='StdCellArea')
    x = pivot.index.values
    fits['req_xbar_slots'] = {}
    for ports in pivot.columns:
        slope, intercept, r, _, _ = linregress(x, pivot[ports].values)
        fits['req_xbar_slots'][int(ports)] = {'slope': slope, 'intercept': intercept, 'r2': r**2}

    rsp = df[df['name'] == 'rsp_xbar']
    pivot = rsp.pivot_table(index='num_rs', columns='num_rsp_ports', values='StdCellArea')
    x = pivot.index.values
    fits['rsp_xbar'] = {}
    for ports in pivot.columns:
        slope, intercept, r, _, _ = linregress(x, pivot[ports].values)
        fits['rsp_xbar'][int(ports)] = {'slope': slope, 'intercept': intercept, 'r2': r**2}

    return fits


def main():
    print(results())


if __name__ == '__main__':
    main()
