#!/usr/bin/env bash
# Download the Nangate45 (FreePDK45) liberty file used by syn/run_syn.sh.
set -euo pipefail
cd "$(dirname "$0")"
curl -sSfL -o NangateOpenCellLibrary_typical.lib \
  https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib
