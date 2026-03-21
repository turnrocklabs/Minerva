/**
 * Base64-encoded icon loading for Stream Deck setImage commands.
 * Icons are loaded from the assets/ directory at build time.
 */

import { readFileSync } from "fs";
import { join, dirname } from "path";

// Resolve asset path relative to the binary or script location
function getAssetsDir(): string {
  // When compiled, process.argv[0] is the binary path
  // Assets are in ../assets/ relative to bin/
  const binDir = dirname(process.argv[0] || ".");
  return join(binDir, "..", "assets");
}

function loadIconBase64(filename: string): string {
  try {
    const assetsDir = getAssetsDir();
    const data = readFileSync(join(assetsDir, filename));
    return "data:image/png;base64," + data.toString("base64");
  } catch {
    return ""; // fallback: empty string resets to default icon
  }
}

// Lazy-load icons on first access
let _cache: Record<string, string> = {};

function icon(name: string): string {
  if (!_cache[name]) {
    _cache[name] = loadIconBase64(name);
  }
  return _cache[name];
}

export const Icons = {
  get pttIdle() { return icon("ptt-idle.png"); },
  get pttActive() { return icon("ptt-active.png"); },
  get inputDeviceDefault() { return icon("input-device-default.png"); },
} as const;
