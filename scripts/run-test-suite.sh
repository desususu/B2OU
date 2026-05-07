#!/bin/sh

set -eu

require_binary() {
    if [ ! -x "$1" ]; then
        echo "Missing built test binary: $1" >&2
        echo "Build the products listed in docs/testing-workflow.md first." >&2
        exit 1
    fi
}

require_binary ./.build/debug/B2OUCoreSmokeTests
require_binary ./.build/debug/B2OUCoreRegressionTests
require_binary ./.build/debug/B2OUCoreContractTests
require_binary ./.build/debug/B2OUWorkflowTests

./.build/debug/B2OUCoreSmokeTests
./.build/debug/B2OUCoreRegressionTests
./.build/debug/B2OUCoreContractTests
./.build/debug/B2OUWorkflowTests
