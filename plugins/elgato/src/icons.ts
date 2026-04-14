/**
 * Static PNG icon loading for Stream Deck setImage commands.
 * Uses setImage for the icon + setTitle for dynamic text overlay.
 */

import { readFileSync } from "fs";
import { join, dirname } from "path";

function getAssetsDir(): string {
  const binDir = dirname(process.argv[0] || ".");
  return join(binDir, "..", "assets");
}

let _cache: Record<string, string> = {};

function loadPng(filename: string): string {
  if (!_cache[filename]) {
    try {
      const data = readFileSync(join(getAssetsDir(), filename));
      _cache[filename] = "data:image/png;base64," + data.toString("base64");
    } catch {
      _cache[filename] = "";
    }
  }
  return _cache[filename];
}

export const Icons = {
  get pttIdle() { return loadPng("ptt-idle.png"); },
  get pttActive() { return loadPng("ptt-active.png"); },
  get pttTranscribing() { return loadPng("ptt-transcribing.png"); },
  get inputDevice() { return loadPng("input-device-default.png"); },
} as const;
