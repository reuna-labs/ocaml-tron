#!/bin/sh
# Builds and runs a Solo5 `sptmac` unikernel that links this library and runs
# the offline Tron path in-guest.
#
# VALIDATION ONLY -- not part of the release. See ../README.md.
#
# The Cardano equivalent (ocaml-cardano/validation/solo5/build.sh) is the model.
# What is different here is GMP: Base58, secp256k1 public-key recovery and the
# ABI's uint256 all need a bignum, so a Tron guest cannot avoid zarith the way
# a Cardano one does. Both are cross-built here, from source, into the
# workspace. Nothing is pinned, nothing is installed, and the shared switch is
# not modified.
#
# See ../../docs/unikernel.md for what each of the four GMP obstacles was.
set -e
: "${OPAMSWITCH:=reuna-5.5}"; export OPAMSWITCH
P="$(opam var prefix)"
S="$P/.opam-switch/sources"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
W="${W:-$(mktemp -d)}"
GMP_VERSION="${GMP_VERSION:-6.3.0}"
GMP_SHA256=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
CACHE="${GMP_CACHE:-$HOME/.cache/ocaml-tron}"
echo "==> workspace: $W"

PATH="$P/bin:$PATH"; export PATH

# --------------------------------------------------------------------------
# 1. GMP, cross-compiled.
#
# Four things stand between stock GMP and this target, none of them a GMP bug:
#
#   - the Solo5 cc wrapper supplies no libc, because it targets a freestanding
#     environment and ocaml-solo5 ships the libc separately;
#   - nolibc and openlibm reference each other, and a static linker only looks
#     forward, so nolibc is repeated;
#   - the allocator is namespaced. ocaml-solo5 force-includes
#     <_solo5/overrides.h> into every C compile through its ocaml-gcc wrapper,
#     so that a unikernel never exports malloc as a strong global symbol --
#     read that header, the sgx reason is sharper than convenience. GMP is
#     built through the plain Solo5 cc wrapper, which does not, so the same
#     header is force-included for it here. GMP then calls ocaml_solo5_malloc
#     like every other C file in the guest;
#   - nolibc's ctype.h is partial and it has no vsprintf. GMP's printf and
#     scanf modules want more, and GCC 14 makes an implicit declaration an
#     error. zarith calls neither module, but GMP builds both unconditionally.
# --------------------------------------------------------------------------
GMP_PREFIX="$W/gmp-prefix"
mkdir -p "$CACHE"
if [ ! -f "$CACHE/gmp-$GMP_VERSION.tar.xz" ]; then
  echo "==> fetching GMP $GMP_VERSION"
  curl --fail --location --retry 5 --retry-all-errors --connect-timeout 20 \
    --output "$CACHE/gmp-$GMP_VERSION.tar.xz" \
    "https://ftp.gnu.org/gnu/gmp/gmp-$GMP_VERSION.tar.xz"
fi
echo "$GMP_SHA256  $CACHE/gmp-$GMP_VERSION.tar.xz" | shasum -a 256 --check --status \
  || { echo "GMP checksum mismatch"; exit 1; }

mkdir -p "$W/gmp-src" "$W/gmp-build" "$W/shim"
tar xf "$CACHE/gmp-$GMP_VERSION.tar.xz" -C "$W/gmp-src" --strip-components 1

cp "$HERE/gmp_solo5_compat.h" "$HERE/nolibc_gaps.c" "$W/shim/"

# The gaps, as an archive, so GMP's configure link-probes resolve. The same
# source is compiled into the guest by dune; this copy exists only for the
# duration of the GMP build.
aarch64-solo5-none-static-cc -c -O2 -std=gnu17 \
  -I"$P/lib/ocaml-solo5/include" \
  -include "$P/lib/ocaml-solo5/include/_solo5/overrides.h" \
  -include "$W/shim/gmp_solo5_compat.h" \
  -o "$W/shim/nolibc_gaps.o" "$W/shim/nolibc_gaps.c"
aarch64-solo5-ocaml-ar rcs "$W/shim/libnolibcgaps.a" "$W/shim/nolibc_gaps.o"

cat > "$W/shim/solo5-gmp-cc" <<CCEOF
#!/bin/sh
# The plain Solo5 cc wrapper, plus what ocaml-solo5's ocaml-gcc wrapper would
# have added: the libc headers, the allocator overrides, and the libraries.
exec "$P/bin/aarch64-solo5-none-static-cc" \\
  -I"$P/lib/ocaml-solo5/include" \\
  -include "$P/lib/ocaml-solo5/include/_solo5/overrides.h" \\
  -include "$W/shim/gmp_solo5_compat.h" \\
  "\$@" \\
  -L"$W/shim" -lnolibcgaps \\
  -L"$P/lib/ocaml-solo5/lib" -lnolibc -lopenlibm -lnolibc
CCEOF
chmod +x "$W/shim/solo5-gmp-cc"

echo "==> configuring GMP for aarch64-solo5"
(cd "$W/gmp-build" && "$W/gmp-src/configure" \
  --host=aarch64-none-elf --build="$(uname -m)-apple-darwin" \
  --prefix="$GMP_PREFIX" \
  --disable-shared --enable-static --disable-assembly \
  CC="$W/shim/solo5-gmp-cc" \
  AR=aarch64-solo5-ocaml-ar RANLIB=aarch64-solo5-ocaml-ranlib \
  CFLAGS="-O2 -std=gnu17" > "$W/gmp-configure.log" 2>&1) \
  || { echo "GMP configure failed, see $W/gmp-configure.log"; exit 1; }

echo "==> building GMP (a few minutes)"
(cd "$W/gmp-build" && make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
  > "$W/gmp-make.log" 2>&1 && make install >> "$W/gmp-make.log" 2>&1) \
  || { echo "GMP build failed, see $W/gmp-make.log"; exit 1; }
echo "    $(aarch64-elf-nm "$GMP_PREFIX/lib/libgmp.a" | grep -c ' T __gmp') gmp symbols"

# --------------------------------------------------------------------------
# 2. The duniverse.
#
# zarith is not a dune package, so it gets a hand-written stanza rather than
# its own configure -- which detects the host GMP and the host stdlib no matter
# what the environment says.
# --------------------------------------------------------------------------
mkdir -p "$W/duniverse"
cp "$HERE"/dune "$HERE"/dune-workspace "$HERE"/dune-project "$W"/
cp "$HERE"/shim.c "$HERE"/manifest.c "$HERE"/manifest.json "$W"/
cp "$HERE"/mirage_mm.c "$HERE"/mirage_clock.c "$W"/
cp "$HERE"/nolibc_gaps.c "$HERE"/gmp_solo5_compat.h "$W"/
cp "$HERE"/unikernel.ml "$HERE"/solo5_exit.ml "$W"/

for d in eqaf.0.10 ocplib-endian.1.2 base64.3.5.2 ptime.1.2.0 yojson.3.0.0 zarith.1.14; do
  cp -R "$S/$d" "$W/duniverse/$(echo "$d" | cut -d. -f1)"
done
# logs comes from ocaml-mpc's duniverse rather than opam's sources: the opam
# copy is not laid out for vendoring, and mirage-crypto-rng needs it. Without
# it the host logs.cmxa is picked up and collides with the Solo5 stdlib.
cp -R "$REPO/../ocaml-mpc/mirage-smoke/duniverse/logs" "$W/duniverse/logs"
cp -R "$S/digestif"      "$W/duniverse/digestif"
cp -R "$S/mirage-crypto" "$W/duniverse/mirage-crypto"
cp -R "$REPO/../../ports/ocaml/mirage-crypto/blockchain-core" "$W/duniverse/mirage-crypto/"
cp -R "$REPO/../../ports/ocaml/mirage-crypto/blockchain"      "$W/duniverse/mirage-crypto/"

# The web3 codec packages and the EVM ABI, from their own repositories.
mkdir -p "$W/duniverse/web3-codec"
for lib in basen base58 protobuf; do
  cp -R "$REPO/../ocaml-web3-codec/lib/$lib" "$W/duniverse/web3-codec/$lib"
done
printf '(dirs basen base58 protobuf)\n' > "$W/duniverse/web3-codec/dune"
mkdir -p "$W/duniverse/evm"
cp -R "$REPO/../ocaml-evm/lib/types" "$W/duniverse/evm/types"
cp -R "$REPO/../ocaml-evm/lib/abi"   "$W/duniverse/evm/abi"
printf '(dirs types abi)\n' > "$W/duniverse/evm/dune"

cp -R "$REPO/lib" "$W/lib"
# The guest links the offline closure. Transports are not in it, by design.
rm -rf "$W"/lib/rpc "$W"/lib/rpc_flow "$W"/lib/rpc_unix "$W"/lib/rpc_grpc "$W"/lib/umbrella

find "$W/duniverse" "$W/lib" -name dune-project -delete
find "$W/duniverse" -maxdepth 2 -name "*.opam" -delete

printf '(dirs eqaf digestif ocplib-endian mirage-crypto base64 ptime yojson zarith web3-codec evm logs)\n' > "$W/duniverse/dune"
printf '(dirs lib config)\n'          > "$W/duniverse/eqaf/dune"
printf '(dirs src src-c src-ocaml)\n' > "$W/duniverse/digestif/dune"
printf '(dirs src)\n'                 > "$W/duniverse/ocplib-endian/dune"
printf '(dirs src)\n'                 > "$W/duniverse/base64/dune"
# ptime is topkg/ocamlbuild, not dune, so it gets a stanza. Only the core
# module is taken: the clock sub-library reads a clock, which is exactly what
# this guest must not link, and nothing here needs it -- the protobuf runtime
# uses Ptime only to render google.protobuf.Timestamp in JSON.
rm -rf "$W/duniverse/ptime/src/clock" "$W/duniverse/ptime/src/top" \
       "$W/duniverse/ptime/test" "$W/duniverse/ptime/doc" \
       "$W/duniverse/ptime/pkg" "$W/duniverse/ptime/myocamlbuild.ml" \
       "$W/duniverse/ptime/B0.ml" "$W/duniverse/ptime/_tags"
rm -f "$W/duniverse/ptime/src/ptime_top_init.ml"
printf '(dirs src)\n' > "$W/duniverse/ptime/dune"
printf '(library (name ptime) (public_name ptime) (modules ptime))\n' \
  > "$W/duniverse/ptime/src/dune"
printf '(dirs src)\n'                 > "$W/duniverse/logs/dune"
printf '(dirs lib)\n'                 > "$W/duniverse/yojson/dune"
printf '(dirs src ec rng blockchain-core blockchain config)\n' > "$W/duniverse/mirage-crypto/dune"

# rng carries sub-packages this guest neither needs nor can build.
rm -rf "$W"/duniverse/mirage-crypto/rng/mirage "$W"/duniverse/mirage-crypto/rng/miou \
       "$W"/duniverse/mirage-crypto/rng/unix "$W"/duniverse/mirage-crypto/rng/mkernel

# zarith: a hand-written stanza. Its own configure detects the host GMP and the
# host stdlib regardless of OCAMLFIND_TOOLCHAIN, so it is bypassed entirely.
cat > "$W/duniverse/zarith/dune" <<ZEOF
(library
 (name zarith)
 (public_name zarith)
 (wrapped false)
 (modules zarith_version z q big_int_Z)
 (foreign_stubs
  (language c)
  (names caml_z)
  (flags -DHAS_GMP -O2 -I$GMP_PREFIX/include))
 (c_library_flags -L$GMP_PREFIX/lib -lgmp))
ZEOF
printf 'let version = "%s"\n' "1.14" > "$W/duniverse/zarith/zarith_version.ml"
rm -f "$W/duniverse/zarith/zarith_top.ml" "$W/duniverse/zarith/Makefile" \
      "$W/duniverse/zarith/configure" "$W/duniverse/zarith/project.mak"
rm -rf "$W/duniverse/zarith/tests"

for p in $(grep -rhoE '\(public_name [a-z0-9._-]+\)' "$W/duniverse" "$W/lib" | sed 's/(public_name //;s/)//' | cut -d. -f1 | sort -u); do
  : > "$W/$p.opam"
done

# --------------------------------------------------------------------------
# 3. Build, and look at what came out.
# --------------------------------------------------------------------------
cd "$W"
GMP_SOLO5_LIB="$GMP_PREFIX/lib"; export GMP_SOLO5_LIB
opam exec -- dune build -x solo5 unikernel.exe
cp _build/default.solo5/unikernel.exe tron-validation.sptmac
chmod u+w tron-validation.sptmac

echo "==> size"; ls -l tron-validation.sptmac | awk '{print "    " $5 " bytes"}'
echo "==> ABI";      opam exec -- solo5-elftool query-abi tron-validation.sptmac
echo "==> manifest"; opam exec -- solo5-elftool query-manifest tron-validation.sptmac
echo "==> gmp is really in there"
aarch64-elf-nm tron-validation.sptmac | grep -c ' [tT] __gmp' | awk '{print "    " $1 " gmp symbols linked"}'
echo "==> run"
if command -v solo5-sptmac >/dev/null; then
  solo5-sptmac tron-validation.sptmac
else
  echo "(solo5-sptmac tender not on PATH; image is at $W/tron-validation.sptmac)"
fi
