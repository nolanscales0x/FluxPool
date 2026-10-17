#!/usr/bin/env bash
# Fetches the five dependencies this package is pinned to into lib/.
#
# You only need this if you did not clone with --recurse-submodules, for example if you downloaded
# the package as a directory or an archive. The commits below are the ones the suite was verified
# against; moving them tests a different tree.
#
# The dependencies carry nested submodules of their own (v4-core vendors solmate and a forge-std,
# v4-periphery vendors permit2), so each is fetched recursively at its pinned commit.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

fetch() {
  local name="$1" url="$2" sha="$3"
  if [ -d "lib/$name" ] && [ -n "$(ls -A "lib/$name" 2>/dev/null)" ]; then
    echo "lib/$name is already present; leaving it alone"
    return 0
  fi
  echo "lib/$name <- $url @ $sha"
  rm -rf "lib/$name"
  git clone --quiet "$url" "lib/$name"
  git -C "lib/$name" checkout --quiet "$sha"
  git -C "lib/$name" submodule update --init --recursive --quiet
}

mkdir -p lib

fetch forge-std               https://github.com/foundry-rs/forge-std               0258fe875e1d8e207c1eb7175e542ea32356773c
fetch openzeppelin-contracts  https://github.com/OpenZeppelin/openzeppelin-contracts fcbae5394ae8ad52d8e580a3477db99814b9d565
fetch uniswap-hooks           https://github.com/OpenZeppelin/uniswap-hooks          1f061b8ec0232608900adfb1a2fa8cd5f6c5a5dc
fetch v4-core                 https://github.com/Uniswap/v4-core                     d153b048868a60c2403a3ef5b2301bb247884d46
fetch v4-periphery            https://github.com/Uniswap/v4-periphery                7ebd04b161745b75ed0c24ba2df3bc7c25f65606

echo
echo "done. next:  FOUNDRY_PROFILE=test forge test --match-contract 'ProtectedLaunchTest|ReviewDemo' -vv"
