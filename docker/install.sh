#!/bin/bash -Eeu

# proptest is a crates.io dependency and a kata runs with no network at all, so
# this image has to hold both the crate sources cargo resolves against and
# everything compiled from them. A press then downloads nothing and compiles
# only the kata's own crate.
#
# Nothing a press writes survives it, because the container is thrown away
# afterwards, so a cache a press fills can never pay for itself. Baking it in
# here is what makes it pay: every press reads this one and none of them
# writes it.

readonly TARGET_CACHE=/rust/target-cache
readonly WARMUP_DIR=/rust/warmup

# Incremental compilation records state for a later build to read back. A press
# is the only build its container ever runs, so nothing ever reads that state
# and writing it is pure cost. It is exported here as well as being set in
# cyber-dojo.sh because a cache is keyed on the flags that filled it: warmed
# with this on and read with it off, every dependency would compile again.
export CARGO_INCREMENTAL=0

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# A warm-up shaped like the start-point kata, so the entries it leaves are the
# ones a kata reaches for. It repeats the start-point's Cargo.toml rather than
# simply depending on proptest, because the package name, the edition, the
# feature and the test profile are all part of what a compiled artifact is
# keyed on, and a warm-up differing in any of them caches under a key no kata
# ever asks for.
mkdir -p "${WARMUP_DIR}/src" "${WARMUP_DIR}/tests"
cd "${WARMUP_DIR}"

cat > Cargo.toml << 'EOF'
[package]
name = "hiker"
version = "0.1.0"
edition = "2024"

[dev-dependencies]
proptest = "1.11.0"

[features]
strict = []

[profile.test]
debug = 0
EOF

cat > src/lib.rs << 'EOF'
#![cfg_attr(feature = "strict", deny(warnings))]

pub fn answer() -> i32 {
    6 * 7
}

pub fn answers(count: usize) -> Vec<i32> {
    vec![answer(); count]
}
EOF

cat > tests/hiker_tests.rs << 'EOF'
#![cfg_attr(feature = "strict", deny(warnings))]

use hiker::answers;
use proptest::prelude::*;

proptest! {
    #[test]
    fn each_hiker_gets_an_answer(count in 0usize..20) {
        prop_assert_eq!(count, answers(count).len());
    }

    #[test]
    fn every_answer_is_42(count in 0usize..20) {
        for given in answers(count) {
            prop_assert_eq!(42, given);
        }
    }
}
EOF

# Downloads proptest and everything below it into this image's cargo registry.
# This is the one command here that needs the network, and it is also the only
# chance to get it: a kata resolves against whatever this leaves behind.
cargo fetch

# From here on every command runs the way a press runs, so what fills the cache
# is keyed the same way as what will read it.
export CARGO_NET_OFFLINE=true

# Compiles proptest, its dependencies, and the test variant of each, then links
# a test binary. Running them as well as building them is what proves the whole
# stack works while there is still someone here to read the error.
CARGO_TARGET_DIR="${TARGET_CACHE}" cargo test --features strict

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# A cache is keyed on the toolchain and the flags that filled it. If those ever
# drift from what cyber-dojo.sh runs, cargo silently compiles the dependencies
# again and a press is merely as slow as it was before. This compares a run
# against the warmed cache with one against an empty one, and insists the warm
# run be several times quicker.
#
# The comparison is against a cold run rather than a fixed number of seconds
# because this same script runs under QEMU when the arm64 half of the image is
# built on an amd64 machine. Emulated, a warm run takes seconds where it takes
# a fraction of one natively, so any threshold that fits one fails the other. A
# ratio holds either way: both runs are slowed by the same emulation.
#
# Each run touches the source first. A press always follows an edit, so a run
# with nothing at all to do would report how fast cargo notices that, which is
# not what any learner waits for.
cargo_test_seconds()
{
  local -r target_dir="${1}"
  touch src/lib.rs
  { TIMEFORMAT='%3R'; time CARGO_TARGET_DIR="${target_dir}" cargo test --features strict > /dev/null 2>&1; } 2>&1
}

readonly COLD_SECONDS=$(cargo_test_seconds /tmp/cold-target)
readonly WARM_SECONDS=$(cargo_test_seconds "${TARGET_CACHE}")
echo "[cargo test] cold ${COLD_SECONDS}s, warm ${WARM_SECONDS}s"
rm -rf /tmp/cold-target

if [ "$(echo "${COLD_SECONDS} > ${WARM_SECONDS} * 3" | bc -l)" != '1' ]; then
  >&2 echo "Expected a warmed cache to be several times quicker than an empty one."
  >&2 echo "The cache is not being hit, so a kata's press will compile proptest."
  exit 42
fi

cd /
rm -rf "${WARMUP_DIR}"

# Both directories are written here by root and read by the sandbox user a kata
# runs as, which also writes to them: the target cache gains the kata's own
# compiled crate, and resolving a kata's dependencies takes a lock file inside
# the registry. So both have to be writable by everyone.
chmod -R 777 "${TARGET_CACHE}" "${CARGO_HOME}"
