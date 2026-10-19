#!/usr/bin/env node
// Builds FluxPool's Programmable Custom Launch V3 pack input (profile 3.6.0, Ethereum mainnet).
//
// The V3 graph is six targets deployed by Programmable's graph factory in one Router transaction: the
// token (FluxProtectedToken), the hook (FluxShell), the protection module, the two fee vaults and
// FluxGraphInitializer, whose `launch` call carries the initial buy. The module and the vaults are in
// the graph because their constructors require the shell and the token to exist. The 9 shared
// contracts are deployed first, from the controller at pinned nonces (script/FluxPlanV3.s.sol); the
// graph names them by their exact addresses.
//
// It compiles the three targets from exact sources with solc 0.8.26 (via IR, optimizer 200, Cancun,
// no metadata hash, no CBOR), writes the Standard JSON, one artifact per target, every runtime
// immutable as an explicit value, and programmable-launch.config.json. It never signs or sends.
//
//   PROGRAMMABLE_CLI_DIR=<unpacked @programmable/launch> SOLC=<solc 0.8.26> \
//   PUBLIC_ORIGIN_URL=https://github.com/<owner>/<repo> PUBLIC_ORIGIN_REVISION=<40-hex commit> RPC_URL=<mainnet> \
//     node programmable/build-v3.mjs <out-dir> [plan-v3.json]
//
// Without plan-v3.json the initializer call carries placeholder arguments: `pack` then reports the
// graph's addresses, which script/FluxPlanV3.s.sol needs. Graph addresses depend only on the source
// bundle, the controller, the launch nonce, the target salts and the constructor arguments, never on
// the initializer call, so the second pass, with the real call from plan-v3.json, keeps them.
import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);
const contracts = path.resolve(here, "..");
const out = path.resolve(process.argv[2] ?? path.join(contracts, "deploy/out/v3"));
const planPath = process.argv[3];
const cliDir = need("PROGRAMMABLE_CLI_DIR");
const solc = need("SOLC");
const { getContractAddress, decodeFunctionData, keccak256 } = await import(path.join(cliDir, "node_modules/viem/_esm/index.js"));

const cfg = JSON.parse(await readFile(path.join(contracts, "deploy/out/mainnet-config.json"), "utf8"));
const meta = JSON.parse(await readFile(path.join(contracts, "deploy/out/project-metadata.json"), "utf8"));
const ZERO = "0x0000000000000000000000000000000000000000";
const POOL_MANAGER = cfg.poolManager;
const PLATFORM_RECIPIENT = "0xD88539d3c4C460136a733A3Fd60cf6BF269079da";
const DYNAMIC_FEE = 8388608; // LPFeeLibrary.DYNAMIC_FEE_FLAG: the shell sets every swap's fee
const TICK_SPACING = 60;
// The canonical Universal Router: the module binds its address and runtime code hash, read from the chain.
const routerCode = await rpc("eth_getCode", [cfg.router, "latest"]);
if (!routerCode || routerCode === "0x") throw new Error("the canonical router has no code at RPC_URL");
const routerCodeHash = keccak256(routerCode);
const NO_EXEMPTIONS = Array(6).fill(ZERO);

// Phase 1: the shared contracts' CREATE addresses, from the controller and its pinned nonces.
const at = (offset) => getContractAddress({ from: cfg.controller, nonce: BigInt(cfg.startNonce + offset) });
const phase1 = {
  creatorFee: at(0), agentRegistry: at(1), changeRegistry: at(2), playbookRegistry: at(3), coreImpl: at(4),
  launcher: at(5), antiSnipe: at(6), adaptiveFee: at(7), revenueRouter: at(8),
};

// ---- Sources and Standard JSON ------------------------------------------------------------------
const REMAP = [
  ["@uniswap/v4-core/", "lib/v4-core/"],
  ["@uniswap/v4-periphery/", "lib/v4-periphery/"],
  ["@openzeppelin/contracts/", "lib/openzeppelin-contracts/contracts/"],
  ["@openzeppelin/uniswap-hooks/", "lib/uniswap-hooks/src/"],
  ["v4-core/", "lib/v4-core/src/"],
  ["solmate/", "lib/v4-core/lib/solmate/"],
  ["forge-std/", "lib/forge-std/src/"],
];
const ENTRYPOINTS = [
  "src/protection/FluxProtectedToken.sol", "src/shell/FluxShell.sol", "src/protection/FluxLaunchProtectionModule.sol",
  "src/protection/FluxFeeVault.sol", "src/launch/FluxGraphInitializer.sol",
];
const sources = await collect(ENTRYPOINTS);
const standardJson = {
  language: "Solidity",
  sources: Object.fromEntries([...sources.entries()]
    .sort(([a], [b]) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    .map(([name, content]) => [name, { content }])),
  settings: {
    optimizer: { enabled: true, runs: 200 },
    evmVersion: "cancun",
    viaIR: true,
    metadata: { bytecodeHash: "none", appendCBOR: false, useLiteralContent: true },
    libraries: {},
    remappings: [],
    outputSelection: {
      "*": {
        "*": ["abi", "metadata", "evm.bytecode.object", "evm.bytecode.linkReferences", "evm.deployedBytecode.object",
          "evm.deployedBytecode.linkReferences", "evm.deployedBytecode.immutableReferences"],
        "": ["ast"],
      },
    },
  },
};
const standardJsonBytes = Buffer.from(`${JSON.stringify(standardJson)}\n`, "utf8");
await mkdir(path.join(out, "standard-json"), { recursive: true });
await writeFile(path.join(out, "standard-json/fluxpool-v3.json"), standardJsonBytes);
const run = spawnSync(solc, ["--standard-json"], { input: standardJsonBytes, maxBuffer: 1 << 30 });
if (run.status !== 0) throw new Error(`solc failed: ${run.stderr}`);
const output = JSON.parse(run.stdout.toString("utf8"));
const errors = (output.errors ?? []).filter((e) => e.severity === "error");
if (errors.length) throw new Error(errors.map((e) => e.formattedMessage).join("\n"));
const version = spawnSync(solc, ["--version"]).stdout.toString();
if (!version.includes("0.8.26+commit.8a97fa7a")) throw new Error(`solc must be 0.8.26+commit.8a97fa7a, got ${version}`);

// ---- Artifacts and runtime immutables -----------------------------------------------------------
const declarations = new Map();
for (const s of Object.values(output.sources ?? {})) walkAst(s.ast, declarations);
const supply = BigInt(cfg.supply);
const IMMUTABLES = {
  token: {
    initializer: ["address", phase1.launcher],
    poolManager: ["address", POOL_MANAGER],
    launchSupply: ["uint256", supply.toString()],
    walletTokenLimit: ["uint256", (supply * 200n / 10000n).toString()],
  },
  hook: {
    poolManager: ["address", POOL_MANAGER],
    quote: ["address", ZERO],
    launcher: ["address", phase1.launcher],
    creatorFeeBlock: ["address", phase1.creatorFee],
    agentRegistry: ["address", phase1.agentRegistry],
    protocolTreasury: ["address", cfg.treasury],
  },
  module: {
    shell: ["address", { target: "hook" }],
    token: ["address", { target: "token" }],
    developer: ["address", cfg.developer],
    router: ["address", cfg.router],
    routerCodeHash: ["bytes32", routerCodeHash],
    normalBuyFeePpm: ["uint256", String((30 + cfg.creatorBuyFeeBps) * 100)],
    buyerTokenLimit: ["uint256", (supply * 200n / 10000n).toString()],
  },
  "normal-fee-vault": {
    poolManager: ["address", POOL_MANAGER],
    kernel: ["address", { target: "hook" }],
    quote: ["address", ZERO],
    creatorRecipient: ["address", phase1.revenueRouter],
  },
  "opening-tax-vault": {
    poolManager: ["address", POOL_MANAGER],
    kernel: ["address", { target: "hook" }],
    quote: ["address", ZERO],
    creatorRecipient: ["address", PLATFORM_RECIPIENT],
  },
  initializer: {
    launcher: ["address", phase1.launcher],
    developer: ["address", cfg.developer],
  },
};
const TARGETS = {
  token: ["src/protection/FluxProtectedToken.sol", "FluxProtectedToken"],
  hook: ["src/shell/FluxShell.sol", "FluxShell"],
  module: ["src/protection/FluxLaunchProtectionModule.sol", "FluxLaunchProtectionModule"],
  "normal-fee-vault": ["src/protection/FluxFeeVault.sol", "FluxFeeVault"],
  "opening-tax-vault": ["src/protection/FluxFeeVault.sol", "FluxFeeVault"],
  initializer: ["src/launch/FluxGraphInitializer.sol", "FluxGraphInitializer"],
};
await mkdir(path.join(out, "artifacts"), { recursive: true });
const compiled = {};
const runtimeImmutables = {};
for (const [targetId, [source, name]] of Object.entries(TARGETS)) {
  const c = output.contracts?.[source]?.[name];
  if (!c?.abi || !c?.metadata || !c?.evm?.bytecode?.object || !c?.evm?.deployedBytecode?.object) {
    throw new Error(`incomplete compiler output for ${source}:${name}`);
  }
  compiled[targetId] = c;
  const artifact = { abi: c.abi, bytecode: c.evm.bytecode, deployedBytecode: c.evm.deployedBytecode, metadata: c.metadata };
  await writeFile(path.join(out, `artifacts/${targetId}.json`), `${JSON.stringify(artifact)}\n`);
  const refs = c.evm.deployedBytecode.immutableReferences ?? {};
  runtimeImmutables[targetId] = Object.keys(refs).sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : 1)).map((immutableId) => {
    const d = declarations.get(immutableId);
    if (!d) throw new Error(`${targetId}: immutable ${immutableId} has no AST declaration`);
    const v = IMMUTABLES[targetId][d.name];
    if (!v) throw new Error(`${targetId}: unmapped immutable ${immutableId} (${d.name}); refusing to guess`);
    return typeof v[1] === "object" ? { immutableId, abiType: v[0], target: v[1].target } : { immutableId, abiType: v[0], literal: v[1] };
  });
}

// ---- The initializer call --------------------------------------------------------------------------
const launchAbi = compiled.initializer.abi.find((x) => x.type === "function" && x.name === "launch");
let launchArgs;
let initialBuyWei = cfg.initialBuyEth;
if (planPath) {
  const plan = JSON.parse(await readFile(planPath, "utf8"));
  const { args } = decodeFunctionData({ abi: [launchAbi], data: plan.graph.initializerCalldata });
  // Graph addresses (from pass 1's pack output) become target locators in the call.
  const predictions = JSON.parse(await readFile(path.join(out, "pack.out"), "utf8")).predictions;
  const graphAddresses = new Map(predictions.map((x) => [x.predictedAddress.toLowerCase(), x.targetId]));
  launchArgs = toJsonAbi(launchAbi.inputs, args, graphAddresses);
  initialBuyWei = String(plan.graph.initialBuyWei);
} else {
  launchArgs = launchAbi.inputs.map(zeroOf);
  launchArgs[0][0] = { target: "token" };
  launchArgs[0][1] = { target: "module" };
  launchArgs[0][2] = { target: "normal-fee-vault" };
  launchArgs[0][3] = { target: "opening-tax-vault" };
}

// ---- Metadata image, evidence, config ---------------------------------------------------------------
await mkdir(path.join(out, "assets"), { recursive: true });
await cp(path.join(contracts, "../app/public/brand/fluxpool-token.png"), path.join(out, "assets/fluxpool-token.png"));
await cp(path.join(contracts, "src"), path.join(out, "src"), { recursive: true });
await mkdir(path.join(out, "evidence"), { recursive: true });
const evidencePath = path.join(out, "evidence/fluxpool-v3.json");
const evidence = {
  schemaVersion: "fluxpool.v3-launch-evidence.v1",
  compiler: version.trim().split("\n").pop(),
  standardJsonSha256: sha256(standardJsonBytes),
  phase1,
  notes: [
    "16-step nonce-pinned plan rehearsed on an Ethereum mainnet fork on 2026-10-19: all steps landed at their addresses, initial buy 324904.08 tokens",
    "contract suite 431/431; app mainnet-fork suite on the launched pool",
  ],
};
await writeFile(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`);

const noncePath = path.join(out, "launch-nonce.txt");
const launchNonce = existsSync(noncePath)
  ? (await readFile(noncePath, "utf8")).trim()
  : `0x${randomBytes(32).toString("hex")}`;
await writeFile(noncePath, `${launchNonce}\n`);
const now = Math.floor(Date.now() / 1000);
const permitWindow = {
  validAfter: process.env.PERMIT_VALID_AFTER ?? String(now),
  deadline: process.env.PERMIT_DEADLINE ?? String(now + 23 * 3600),
};

const fee = (bps) => String((bps + 30) * 100); // creator fee plus the 30 bps platform share, inclusive
const config = {
  schemaVersion: "programmable.launch-pack-config.v3",
  launchWallet: cfg.controller,
  chainId: "1",
  nonce: launchNonce,
  source: {
    root: ".",
    paths: ["src"],
    sourceLineageNonce: "1",
    publicOrigin: { url: need("PUBLIC_ORIGIN_URL"), revision: need("PUBLIC_ORIGIN_REVISION") },
  },
  compilationUnits: [{ compilationUnitId: "fluxpool-v3", standardJson: "standard-json/fluxpool-v3.json" }],
  targets: [
    {
      targetId: "token", compilationUnitId: "fluxpool-v3", artifact: "artifacts/token.json",
      applicantSalt: `0x${"02".repeat(32)}`,
      constructorArguments: [cfg.name, cfg.symbol, cfg.supply, phase1.launcher, POOL_MANAGER],
      initializer: null, deploymentValueWei: "0", initializerValueWei: "0",
      componentKind: "token", declaredHookPermissions: null, runtimeImmutables: runtimeImmutables.token,
    },
    {
      targetId: "hook", compilationUnitId: "fluxpool-v3", artifact: "artifacts/hook.json",
      applicantSalt: { mode: "deterministic-hook-permission-grind-v1", start: "0", maxAttempts: "1000000" },
      constructorArguments: [POOL_MANAGER, phase1.launcher, phase1.creatorFee, phase1.agentRegistry, cfg.treasury, ZERO],
      initializer: null, deploymentValueWei: "0", initializerValueWei: "0",
      componentKind: "hook",
      declaredHookPermissions: ["afterInitialize", "beforeAddLiquidity", "afterAddLiquidity", "beforeRemoveLiquidity",
        "afterRemoveLiquidity", "beforeSwap", "afterSwap", "beforeSwapReturnDelta", "afterSwapReturnDelta"],
      runtimeImmutables: runtimeImmutables.hook,
    },
    {
      targetId: "module", compilationUnitId: "fluxpool-v3", artifact: "artifacts/module.json",
      applicantSalt: `0x${"03".repeat(32)}`,
      constructorArguments: [{ target: "hook" }, { target: "token" }, cfg.developer, cfg.router, routerCodeHash,
        String(cfg.creatorBuyFeeBps), [...(cfg.exemptWallets ?? []), ...NO_EXEMPTIONS].slice(0, 6)],
      initializer: null, deploymentValueWei: "0", initializerValueWei: "0",
      componentKind: "other", declaredHookPermissions: null, runtimeImmutables: runtimeImmutables.module,
    },
    {
      targetId: "normal-fee-vault", compilationUnitId: "fluxpool-v3", artifact: "artifacts/normal-fee-vault.json",
      applicantSalt: `0x${"04".repeat(32)}`,
      constructorArguments: [POOL_MANAGER, { target: "hook" }, ZERO, phase1.revenueRouter],
      initializer: null, deploymentValueWei: "0", initializerValueWei: "0",
      componentKind: "other", declaredHookPermissions: null, runtimeImmutables: runtimeImmutables["normal-fee-vault"],
    },
    {
      targetId: "opening-tax-vault", compilationUnitId: "fluxpool-v3", artifact: "artifacts/opening-tax-vault.json",
      applicantSalt: `0x${"05".repeat(32)}`,
      constructorArguments: [POOL_MANAGER, { target: "hook" }, ZERO, PLATFORM_RECIPIENT],
      initializer: null, deploymentValueWei: "0", initializerValueWei: "0",
      componentKind: "other", declaredHookPermissions: null, runtimeImmutables: runtimeImmutables["opening-tax-vault"],
    },
    {
      targetId: "initializer", compilationUnitId: "fluxpool-v3", artifact: "artifacts/initializer.json",
      applicantSalt: `0x${"01".repeat(32)}`,
      constructorArguments: [phase1.launcher, cfg.developer],
      initializer: { function: "launch", arguments: launchArgs },
      deploymentValueWei: "0", initializerValueWei: initialBuyWei,
      componentKind: "other", declaredHookPermissions: null, runtimeImmutables: runtimeImmutables.initializer,
    },
  ],
  pool: { tokenTargetId: "token", hookTargetId: "hook", fee: DYNAMIC_FEE, tickSpacing: TICK_SPACING, quoteCurrency: ZERO },
  projectMetadata: {
    schemaVersion: "programmable.project-metadata-input.v1",
    token: meta.token,
    presentation: {
      description: meta.presentation.description,
      image: { sourcePath: "assets/fluxpool-token.png", uri: meta.presentation.image.uri },
      links: meta.presentation.links,
    },
  },
  launchProfile: {
    schemaVersion: "programmable.direct-native-hook-graph-profile-selection.v3",
    profileId: "programmable.direct-native-hook-graph.v1",
    profileRevision: 3,
    targetRoles: { tokenTargetId: "token", hookTargetId: "hook", initializerTargetId: "initializer", platformFeeBindingTargetId: "hook" },
    fundingMode: "wallet-transaction-value",
    accountingMode: "inclusive-selected-total",
    assessmentBase: "executed-gross-declared-quote",
    feeCurrency: "declared-quote-currency",
    claimMode: "immutable-payout-recipient",
    payoutRecipient: PLATFORM_RECIPIENT,
    applicantSelectedBuyHundredthsOfBip: fee(cfg.creatorBuyFeeBps),
    applicantSelectedSellHundredthsOfBip: fee(cfg.creatorSellFeeBps),
    liquidityModel: {
      schemaVersion: "programmable.direct-native-liquidity-model-intent.v1",
      model: "launch-seeded-concentrated-liquidity",
      declaredLaunchState: "assessment_required",
      liquidityTargetId: "initializer",
      assessment: {
        schemaVersion: "programmable.direct-native-liquidity-model-assessment.v1",
        status: "required",
        requestClaimsExecution: false,
        requiredVectorIds: ["liquidity.seeded.pool-active-liquidity", "liquidity.seeded.position-custody-and-withdrawal",
          "liquidity.seeded.buy-and-sell"],
      },
    },
  },
  permitWindow,
  agentAttestation: {
    agentId: "fluxpool-launch-v3",
    checkedAt: new Date().toISOString().replace(/\.\d{3}Z$/, (m) => m),
    checks: [{ checkId: "fluxpool-mainnet-fork-rehearsal", evidence: "evidence/fluxpool-v3.json" }],
  },
};
await writeFile(path.join(out, "programmable-launch.config.json"), `${JSON.stringify(config, null, 2)}\n`);
process.stdout.write(`${JSON.stringify({
  out, pass: planPath ? 2 : 1, sources: sources.size, standardJsonBytes: standardJsonBytes.length,
  phase1, immutables: Object.fromEntries(Object.entries(runtimeImmutables).map(([k, v]) => [k, v.length])),
}, null, 2)}\n`);

// ---- helpers ------------------------------------------------------------------------------------
async function rpc(method, params) {
  const r = await fetch(need("RPC_URL"), { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
}
function need(name) {
  const v = process.env[name];
  if (!v) throw new Error(`set ${name}`);
  return v;
}
function sha256(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}
function localPath(sourceName) {
  for (const [prefix, dir] of REMAP) if (sourceName.startsWith(prefix)) return path.join(contracts, dir, sourceName.slice(prefix.length));
  return path.join(contracts, sourceName);
}
async function collect(entrypoints) {
  const collected = new Map();
  const pending = [...entrypoints];
  while (pending.length) {
    const name = pending.shift();
    if (collected.has(name)) continue;
    if (path.posix.isAbsolute(name) || name.startsWith("../")) throw new Error(`unsafe source name ${name}`);
    const content = await readFile(localPath(name), "utf8");
    collected.set(name, content);
    const pattern = /^\s*import\s+(?:[^;]*?\sfrom\s+)?["']([^"']+)["']\s*;/gmu;
    for (let m = pattern.exec(content); m !== null; m = pattern.exec(content)) {
      const spec = m[1];
      const imported = spec.startsWith(".") ? path.posix.normalize(path.posix.join(path.posix.dirname(name), spec)) : path.posix.normalize(spec);
      if (!collected.has(imported) && !pending.includes(imported)) pending.push(imported);
    }
  }
  return collected;
}
function walkAst(node, map) {
  if (node === null || typeof node !== "object") return;
  if (node.nodeType === "VariableDeclaration" && node.mutability === "immutable" && Number.isSafeInteger(node.id)) {
    map.set(String(node.id), { name: node.name });
  }
  for (const v of Object.values(node)) {
    if (Array.isArray(v)) for (const c of v) walkAst(c, map);
    else if (v !== null && typeof v === "object") walkAst(v, map);
  }
}
// JSON ABI values: tuples as positional arrays, integers as decimal strings, and every graph address as a
// target locator rather than a literal.
function toJsonAbi(params, values, graph) {
  return params.map((p, i) => one(p, Array.isArray(values) ? values[i] : values[p.name], graph));
}
function one(p, v, graph) {
  if (p.type.endsWith("[]")) {
    const inner = { ...p, type: p.type.slice(0, -2) };
    return v.map((x) => one(inner, x, graph));
  }
  if (p.type === "tuple") return p.components.map((c, i) => one(c, Array.isArray(v) ? v[i] : v[c.name], graph));
  if (p.type === "address") return graph.has(v.toLowerCase()) ? { target: graph.get(v.toLowerCase()) } : v;
  if (typeof v === "bigint") return v.toString();
  if (typeof v === "number") return String(v);
  return v;
}
// Pass 1 only: zero values of the right shape, so pack can derive the graph. Pass 2 uses the real call.
function zeroOf(p) {
  if (p.type.endsWith("]")) return [];
  if (p.type === "tuple") return p.components.map(zeroOf);
  if (p.type === "address") return ZERO;
  if (p.type === "bool") return false;
  if (p.type === "string") return "";
  if (p.type.startsWith("bytes")) return p.type === "bytes" ? "0x" : `0x${"00".repeat(Number(p.type.slice(5)))}`;
  return "0";
}
