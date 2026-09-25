#!/bin/sh
# Rebuild the brand assets in `Assets.xcassets` from the artwork export.
#
#   ./run.sh [path/to/art.png]
#
# The default is the export the current assets were built from. See the script's own header for
# what it does to the art and why.
set -eu
cd "$(dirname "$0")"
exec python3 ./make-brand-assets.py "$@"
