#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
#
# Regenerate the Ruby wire codec from the vendored `program.proto`.
#
#   gen/gen.sh
#
# `proto/quicopt/modeler/v1/program.proto` is the published wire contract; the
# generated code under `lib/quicopt/modeler/` is committed, so this script is only
# re-run when the schema changes. Mirrors `QuicoptClient/gen/gen.jl`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO="quicopt/modeler/v1/program.proto"   # path relative to the proto root

command -v protoc >/dev/null || { echo "gen.sh: protoc not found (brew install protobuf)" >&2; exit 1; }

protoc \
  --proto_path="$ROOT/proto" \
  --ruby_out="$ROOT/lib" \
  "$PROTO"

# Stamp the SPDX header onto the generated file (rewritten on each run).
OUT="$ROOT/lib/quicopt/modeler/v1/program_pb.rb"
if ! head -n 1 "$OUT" | grep -q SPDX; then
  printf '%s\n%s\n%s\n' \
    '# SPDX-License-Identifier: Apache-2.0' \
    '# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich' \
    '' | cat - "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
fi

echo "gen.sh: generated wire codec into lib/quicopt/modeler/"
