#!/usr/bin/env bash
# control-mac-chrome.sh — tiny wrapper so you don't have to remember NODE_PATH.
# Runs the Node example script with globally-installed puppeteer-core visible.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NODE_PATH="$(npm root -g)"
export NODE_PATH
exec node "$HERE/control-mac-chrome.js" "$@"
