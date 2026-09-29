# Copyright 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

import ctypes
from pathlib import Path
import os
import signal
import subprocess
import sys
from termcolor import colored
import time

MK_DIR = Path(__file__).resolve().parent / '../../'


# Set the parent-death signal of the current process to `sig`.
def _set_pdeathsig(sig=signal.SIGTERM):
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    PR_SET_PDEATHSIG = 1
    if libc.prctl(PR_SET_PDEATHSIG, sig) != 0:
        e = ctypes.get_errno()
        raise OSError(e, "prctl(PR_SET_PDEATHSIG) failed")


def join_cdefines(defines):
    return ' '.join([f'-D{key}={value}' for key, value in defines.items()])


def extend_environment(vars, env=None):
    if env is None:
        env = os.environ.copy()
    env.update(vars)
    return env


def run(cmd, env=None, dry_run=False, sync=True, log_file=None):
    cmd = [str(arg) for arg in cmd]
    if dry_run:
        print(' '.join(cmd))
        return None
    else:
        if log_file is not None:
            Path(log_file).parent.mkdir(parents=True, exist_ok=True)
            with open(log_file, 'w') as f:
                if sync:
                    process = subprocess.run(
                        cmd, env=env, stdout=f, stderr=subprocess.STDOUT,
                        preexec_fn=_set_pdeathsig)
                else:
                    process = subprocess.Popen(
                        cmd, env=env, stdout=f, stderr=subprocess.STDOUT,
                        preexec_fn=_set_pdeathsig)
        elif sync:
            process = subprocess.run(cmd, env=env, preexec_fn=_set_pdeathsig)
        else:
            process = subprocess.Popen(cmd, env=env, preexec_fn=_set_pdeathsig)
        process.log_file = log_file
        return process


def make(target, vars={}, flags=[], dir=MK_DIR, env=None, dry_run=False, sync=True,
         log_file=None):
    var_assignments = [f'{key}={value}' for key, value in vars.items()]
    cmd = ['make', *var_assignments, target]
    if dir is not None:
        cmd.extend(['-C', dir])
    cmd.extend(flags)
    return run(cmd, env=env, dry_run=dry_run, sync=sync, log_file=log_file)


def _check_returncode(p, retcode):
    if retcode != 0:
        print(
            colored(f'Process failed with exit code {retcode}:\n', 'red', attrs=['bold']),
            colored(f'{" ".join(p.args)}', 'black')
        )
        if getattr(p, 'log_file', None) is not None:
            print(colored(f'See log: {p.log_file}', 'red', attrs=['bold']))
        sys.exit(1)


def labelled(p, label):
    """Attach a label to a process, to be reported when it completes. Passes `None` through."""
    if p is not None:
        p.label = label
    return p


def wait_processes(processes, dry_run=False):
    if not dry_run:
        for i, p in enumerate(processes):
            # If process was launched in synchronous mode, it must have finished, and return code
            # can be retrieved
            retcode = p.returncode
            # Otherwise wait for process to finish, and only then read return code
            if retcode is None:
                retcode = p.wait()
            # Check return code
            _check_returncode(p, retcode)


def run_bounded(launchers, n_procs=1, dry_run=False, poll_interval=0.5):
    """Run jobs concurrently, with at most `n_procs` running at any time.

    Args:
        launchers: List of zero-argument callables. Each starts a job asynchronously
            (`sync=False`) and returns its process. A job is only launched once a slot is free.
        n_procs: Maximum number of jobs to run in parallel.
        dry_run: If set, the launchers are only invoked (to print their commands).
    """
    if dry_run:
        for launch in launchers:
            launch()
        return
    pending = list(launchers)
    running = []
    while pending or running:
        # Fill free slots
        while pending and len(running) < n_procs:
            running.append(pending.pop(0)())
        # Reap finished jobs, exiting on the first failure
        time.sleep(poll_interval)
        still_running = []
        for p in running:
            retcode = p.poll()
            if retcode is None:
                still_running.append(p)
            else:
                _check_returncode(p, retcode)
                label = getattr(p, 'label', None) or ' '.join(str(a) for a in p.args)
                print(colored(f'{label} completed', 'green', attrs=['bold']))
        running = still_running
