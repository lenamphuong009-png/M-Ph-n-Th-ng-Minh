#!/bin/sh
# Lệnh build Netlify cho Memorial Engine. Toàn bộ kiểm tra nằm trong tn-build.mjs (fail-closed).
set -eu
cd "$(dirname "$0")/.."
exec node scripts/tn-build.mjs
