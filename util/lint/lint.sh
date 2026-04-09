#!/usr/bin/env bash
# Copyright 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Run lint checks locally, mirroring the CI configuration.

set -euo pipefail

FAILED=0

echo "==> Python (flake8)"
git ls-files '*.py' | xargs -r flake8 || FAILED=1

echo "==> C/C++ (clang-format)"
CLANGFMT_EXCLUDE=$(grep -v '^\s*#' .clang-format-ignore | grep -v '^\s*$' | sed 's|^\./||' | paste -sd '|')
git ls-files '*.c' '*.cc' '*.cpp' '*.cxx' '*.h' '*.hh' '*.hpp' '*.hxx' | \
    grep -vE "^($CLANGFMT_EXCLUDE)" | \
    xargs -r clang-format-10.0.1 --dry-run --Werror || FAILED=1

exit "$FAILED"
