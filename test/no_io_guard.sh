#!/bin/sh
#
# The offline packages must stay free of I/O.
#
# Checks *declared* dependencies rather than grepping sources. That is what
# actually determines what a unikernel links: a file that never writes `Unix.`
# still drags in unix if its package declares it, and a file that mentions Unix
# in a comment does not.
#
# Two checks, and the second is the one that would catch a dependency acquiring
# unix without this repository changing:
#
#   1. No offline package's `depends:` names a forbidden package, directly or
#      through another package in this repository.
#   2. The validation unikernel, which links the offline closure and no
#      transport, still links. If the closure grows a Unix dependency anywhere
#      -- including inside a package we do not own -- this stops building.
#
# Run from the repository root. Exits non-zero on the first violation.

set -eu

DUNE="${DUNE:-dune}"

# Everything a signature covers, plus the transport-free RPC layer. Deliberately
# not the transports: those own a socket, which is their job.
OFFLINE="tron-types tron-crypto tron-proto tron-transaction tron-rpc tron"

# The transports that must still reach a Solo5 vsock. They are allowed Lwt and
# a flow; they are not allowed anything that assumes a host operating system or
# a TCP stack. tron-rpc-unix is deliberately absent -- being Unix-specific is
# what it is for.
FLOW_TRANSPORTS="tron-rpc-flow tron-rpc-grpc"

# unix and threads are the direct hazards. lwt, cohttp, conduit and
# mirage-flow* are listed because they are the usual ways unix arrives without
# anyone naming it.
FORBIDDEN="unix threads lwt cohttp cohttp-lwt cohttp-lwt-unix conduit conduit-lwt
conduit-lwt-unix mirage-flow mirage-flow-unix mirage-crypto-rng-unix ptime-clock
mtime-clock ptime.clock.os core_unix async"

# What a flow transport may not have. Lwt and mirage-flow are fine here; a host
# operating system or a network stack is not. h2-mirage is on the list because
# reaching for it instead of Io_of_flow would quietly pull conduit-mirage,
# tcpip and 46 other packages, and with them the assumption of a stack the
# confidential targets do not have.
FLOW_FORBIDDEN="unix threads lwt.unix cohttp-lwt-unix conduit-lwt-unix
mirage-flow-unix h2-lwt-unix h2-mirage tcpip conduit-mirage core_unix async"

status=0

fail() {
  echo "no_io_guard: FAIL $*" >&2
  status=1
}

# The package names inside a .opam depends: block, one per line. Filters out
# the build-only and test-only entries, which do not reach a unikernel.
declared_deps() {
  awk '
    /^depends: \[/ { inside = 1; next }
    inside && /^\]/  { inside = 0 }
    inside {
      if ($0 ~ /with-test|with-doc|with-dev-setup/) next
      if (match($0, /"[^"]+"/)) {
        name = substr($0, RSTART + 1, RLENGTH - 2)
        if (name != "ocaml" && name != "dune") print name
      }
    }
  ' "$1"
}

# Walks a package's declared dependencies, following the ones that live in
# this repository so a violation one level down is still found here.
check_package() {
  pkg="$1"
  shift
  forbidden="$*"
  file="$pkg.opam"
  [ -f "$file" ] || { fail "$file is missing -- run dune build @install"; return; }

  pending=$(declared_deps "$file")
  seen=""
  bad=""
  while [ -n "$pending" ]; do
    dep=$(printf '%s\n' "$pending" | head -n 1)
    pending=$(printf '%s\n' "$pending" | tail -n +2)
    case " $seen " in *" $dep "*) continue ;; esac
    seen="$seen $dep"

    for f in $forbidden; do
      [ "$dep" = "$f" ] && bad="$bad $dep"
    done

    if [ -f "$dep.opam" ]; then
      pending=$(printf '%s\n%s\n' "$pending" "$(declared_deps "$dep.opam")" | grep -v '^$' || true)
    fi
  done

  if [ -n "$bad" ]; then
    fail "$pkg depends on:$bad"
  else
    echo "  ok  $pkg"
  fi
}

echo "no_io_guard: declared dependencies"

for pkg in $OFFLINE; do
  check_package "$pkg" $FORBIDDEN
done

echo "no_io_guard: flow transports stay free of a host OS"

for pkg in $FLOW_TRANSPORTS; do
  check_package "$pkg" $FLOW_FORBIDDEN
done

# The check that does not rely on us having listed every hazard: link the
# offline closure into a Solo5-shaped executable that names no transport.
if [ -f validation/solo5/dune ]; then
  echo "no_io_guard: linking the offline closure with no transport"
  if "$DUNE" build validation/solo5/unikernel.exe 2>&1; then
    echo "  ok  validation/solo5/unikernel.exe"
  else
    fail "the offline closure no longer links without a transport"
  fi
else
  echo "no_io_guard: WARNING validation/solo5 is absent, link proof skipped" >&2
fi

# And the same question for gRPC, which claims to reach a vsock too: it must
# build over a flow that is not a socket, naming no Unix package.
if [ -f validation/grpc-flow/dune ]; then
  echo "no_io_guard: linking gRPC over a non-socket flow"
  if "$DUNE" build validation/grpc-flow/grpc_flow_link.exe 2>&1; then
    echo "  ok  validation/grpc-flow/grpc_flow_link.exe"
  else
    fail "gRPC no longer builds over an arbitrary flow"
  fi
else
  echo "no_io_guard: WARNING validation/grpc-flow is absent, gRPC link proof skipped" >&2
fi

if [ "$status" -eq 0 ]; then
  echo "no_io_guard: clean"
else
  echo "no_io_guard: violations found" >&2
fi
exit "$status"
