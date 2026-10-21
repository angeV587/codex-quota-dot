#!/bin/zsh
set -eu
cd -- "${0:A:h:h}"
mkdir -p .build docs
swiftc -gnone Sources/StatusGraphic.swift scripts/render-preview.swift -o .build/RenderPreview
.build/RenderPreview docs/preview.png
