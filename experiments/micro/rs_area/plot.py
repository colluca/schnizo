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
    df['StdCellArea'] = df['StdCellArea'].map(to_kge).round(0).astype('int')
    df['hierarchy_details'] = df['synth_results'].str['hierarchy_details']
    df['CombArea'] = df['hierarchy_details'].map(lambda x: to_kge(x.tree.get_attr('CombArea')))
    df['SeqArea'] = df['hierarchy_details'].map(lambda x: to_kge(x.tree.get_attr('SeqArea')))
    df['MacroBBArea'] = df['hierarchy_details'].map(
        lambda x: to_kge(x.tree.get_attr('MacroBBArea'))
    )
    df['CombArea'] = df['CombArea'].round(0).astype('int')
    df['SeqArea'] = df['SeqArea'].round(0).astype('int')
    df['MacroBBArea'] = df['MacroBBArea'].round(0).astype('int')
    df['1BitEqSeq'] = (df['synth_results'].str['multibit'].str['1BitEqSeq']).astype('int')
    df['GE/bit'] = (1e3 * df['SeqArea'] / df['1BitEqSeq']).round(1)

    df.drop(columns=['hierarchy_details'], inplace=True)
    df.drop(columns=['synth_results'], inplace=True)

    return df


def plot(dir=None, show=False):
    df = results(dir=dir)

    df = df[df['ConsumerCount'] == 64]

    # Pivot: one group per NofRss, one bar per NofOperands
    plot_df = df.pivot_table(index='NofRss', columns='NofOperands', values='StdCellArea')
    plot_df.columns = [f'{ops} operands' for ops in plot_df.columns]

    fig, ax = plt.subplots()
    plot_df.plot(kind='bar', ax=ax, zorder=3)

    ax.set_xlabel('Number of RSEs')
    ax.set_ylabel('Area [kGE]')
    ax.set_xticklabels(plot_df.index, rotation=0)
    ax.legend()
    ax.set_axisbelow(True)
    ax.grid(True, axis='y', color='gainsboro', linewidth=0.5, alpha=0.7)
    fig.tight_layout()

    if show:
        plt.show()

    return plot_df


def main():
    print(results())


if __name__ == '__main__':
    main()
