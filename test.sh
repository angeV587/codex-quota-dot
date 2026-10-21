#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
swiftc Sources/QuotaModel.swift Sources/StatusGraphic.swift Sources/CodexClient.swift Tests/main.swift -o .build/QuotaChecks
.build/QuotaChecks
