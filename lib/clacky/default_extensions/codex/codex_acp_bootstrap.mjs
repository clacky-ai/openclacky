#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { createRequire } from "node:module";
import { delimiter, dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

const ADAPTER_NAME = "@agentclientprotocol/codex-acp";
const ADAPTER_VERSION = "1.11.0";
const CODEX_NAME = "@openai/codex";
const CODEX_VERSION = "0.153.4";
const RUN_ARGUMENT = "--openclacky-run";
const EXPECTED_SOURCE_SHA256 =
  "3527bdaf90a219175c742576963e6d9e943e4ea5fbdbc3e04e7f57f9a9e11343";
const TRUSTED_PROJECT_SNIPPET = `projects: Object.fromEntries(sessionRoots.map((root) => [root, {
        trust_level: "trusted"
      }]))`;
const UNTRUSTED_PROJECT_SNIPPET = `projects: Object.fromEntries(sessionRoots.map((root) => [root, {
        trust_level: "untrusted"
      }]))`;

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

export function patchAdapterSource(
  source,
  expectedDigest = EXPECTED_SOURCE_SHA256,
) {
  const actualDigest = sha256(source);
  if (actualDigest !== expectedDigest) {
    throw new Error(
      `Refusing unverified ${ADAPTER_NAME} source: expected ${expectedDigest}, got ${actualDigest}`,
    );
  }

  const occurrences = source.split(TRUSTED_PROJECT_SNIPPET).length - 1;
  if (occurrences !== 1) {
    throw new Error(
      `Refusing incompatible ${ADAPTER_NAME} source: expected one project trust marker, got ${occurrences}`,
    );
  }

  return source.replace(TRUSTED_PROJECT_SNIPPET, UNTRUSTED_PROJECT_SNIPPET);
}

function executableFromPath(name) {
  for (const directory of (process.env.PATH || "").split(delimiter)) {
    if (!directory) continue;
    const candidate = join(directory, name);
    if (existsSync(candidate)) return realpathSync(candidate);
  }
  return null;
}

function adapterTarget() {
  const supplied = process.argv[3];
  const candidate = supplied ? resolve(supplied) : executableFromPath("codex-acp");
  if (!candidate || !existsSync(candidate)) {
    throw new Error(`Unable to locate pinned ${ADAPTER_NAME}@${ADAPTER_VERSION}`);
  }
  return realpathSync(candidate);
}

function secureRuntimeDirectory(codexHome) {
  const runtimeDirectory = join(codexHome, "openclacky-runtime");
  mkdirSync(runtimeDirectory, { recursive: true, mode: 0o700 });
  const stat = lstatSync(runtimeDirectory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error("OpenClacky Codex runtime path must be a real directory");
  }
  chmodSync(runtimeDirectory, 0o700);
  return runtimeDirectory;
}

function materializePatchedAdapter(source, codexHome) {
  const patched = patchAdapterSource(source);
  const digest = sha256(patched);
  const runtimeDirectory = secureRuntimeDirectory(codexHome);
  const destination = join(
    runtimeDirectory,
    `codex-acp-${ADAPTER_VERSION}-${digest}.mjs`,
  );

  if (existsSync(destination)) {
    const stat = lstatSync(destination);
    if (stat.isFile() && !stat.isSymbolicLink()) {
      const existing = readFileSync(destination, "utf8");
      if (sha256(existing) === digest) return destination;
    }
    throw new Error("OpenClacky Codex adapter cache failed integrity validation");
  }

  const temporary = `${destination}.${process.pid}.tmp`;
  try {
    writeFileSync(temporary, patched, { encoding: "utf8", flag: "wx", mode: 0o600 });
    renameSync(temporary, destination);
  } finally {
    if (existsSync(temporary)) unlinkSync(temporary);
  }
  return destination;
}

function packageMetadataFor(entrypoint, expectedName) {
  let directory = dirname(realpathSync(entrypoint));
  for (;;) {
    const packagePath = join(directory, "package.json");
    if (existsSync(packagePath)) {
      const metadata = JSON.parse(readFileSync(packagePath, "utf8"));
      if (metadata.name === expectedName) return metadata;
    }

    const parent = dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }
  throw new Error(`Unable to locate ${expectedName} package metadata`);
}

export function resolveVerifiedCodex(adapterPath, expectedVersion = CODEX_VERSION) {
  const bundledCodex = realpathSync(
    createRequire(adapterPath).resolve("@openai/codex/bin/codex.js"),
  );
  const metadata = packageMetadataFor(bundledCodex, CODEX_NAME);
  if (metadata.version !== expectedVersion) {
    throw new Error(
      `Refusing incompatible ${CODEX_NAME}: expected ${expectedVersion}, got ${metadata.version || "unknown"}`,
    );
  }
  return bundledCodex;
}

function verifyCodexOverride(codexPath) {
  const resolved = realpathSync(codexPath);
  const probe = spawnSync(resolved, ["--version"], {
    encoding: "utf8",
    env: process.env,
    timeout: 10_000,
  });
  const output = `${probe.stdout || ""}\n${probe.stderr || ""}`;
  const escapedVersion = CODEX_VERSION.replaceAll(".", "\\.");
  const exactVersion = new RegExp(`(?:^|\\D)${escapedVersion}(?![\\d.+-])`);
  if (probe.status !== 0 || !exactVersion.test(output)) {
    throw new Error(
      `Refusing incompatible CODEX_PATH: expected Codex ${CODEX_VERSION}`,
    );
  }
  return resolved;
}

function configureBundledCodex(adapterPath) {
  if (process.env.CODEX_PATH) {
    process.env.CODEX_PATH = verifyCodexOverride(process.env.CODEX_PATH);
    return;
  }

  process.env.CODEX_PATH = resolveVerifiedCodex(adapterPath);
}

async function main() {
  const suppliedTarget = process.argv[3] ? true : false;
  const adapterPath = adapterTarget();
  const source = readFileSync(adapterPath, "utf8");
  const codexHome = process.env.CODEX_HOME;
  if (!codexHome) throw new Error("CODEX_HOME is required");

  configureBundledCodex(adapterPath);
  const patchedPath = materializePatchedAdapter(source, codexHome);
  const adapterArguments = suppliedTarget ? process.argv.slice(4) : process.argv.slice(3);
  process.argv = [process.argv[0], patchedPath, ...adapterArguments];
  await import(pathToFileURL(patchedPath).href);
}

if (process.argv[2] === RUN_ARGUMENT) {
  main().catch((error) => {
    process.stderr.write(`OpenClacky Codex bootstrap failed: ${error.message}\n`);
    process.exitCode = 1;
  });
}
