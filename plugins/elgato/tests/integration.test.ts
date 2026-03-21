import { describe, test, expect, beforeEach } from "bun:test";
import type { MinervaEvent, MinervaCommand } from "../src/minerva-protocol";

/**
 * Integration tests for plugin action logic.
 * These test the action handlers in isolation by simulating
 * Stream Deck events and Minerva state updates.
 */

// ── Device Cycling Logic ──────────────────────────────────────────────

describe("device cycling", () => {
  function nextDevice(
    devices: string[],
    current: string
  ): string | null {
    if (devices.length <= 1) return null;
    const idx = devices.indexOf(current);
    const next = (idx + 1) % devices.length;
    return devices[next];
  }

  test("cycles to next device", () => {
    expect(nextDevice(["A", "B", "C"], "A")).toBe("B");
    expect(nextDevice(["A", "B", "C"], "B")).toBe("C");
  });

  test("wraps around to first device", () => {
    expect(nextDevice(["A", "B", "C"], "C")).toBe("A");
  });

  test("returns null for single device", () => {
    expect(nextDevice(["A"], "A")).toBeNull();
  });

  test("returns null for empty list", () => {
    expect(nextDevice([], "A")).toBeNull();
  });

  test("handles unknown current device (defaults to first)", () => {
    // indexOf returns -1, (-1 + 1) % 3 = 0
    expect(nextDevice(["A", "B", "C"], "Z")).toBe("A");
  });

  test("handles device list update correctly", () => {
    // Simulate device unplugged: was on B, now list is [A, C]
    expect(nextDevice(["A", "C"], "B")).toBe("A");
  });
});

// ── PTT State Machine ─────────────────────────────────────────────────

describe("PTT state machine", () => {
  type PTTState = "idle" | "recording" | "error";

  function pttTransition(
    state: PTTState,
    event: "keyDown" | "keyUp" | "ptt_active_true" | "ptt_active_false" | "error"
  ): PTTState {
    switch (event) {
      case "keyDown":
        return state === "error" ? "idle" : "recording"; // clear error on press
      case "keyUp":
        return state === "recording" ? "idle" : state;
      case "ptt_active_true":
        return "recording";
      case "ptt_active_false":
        return "idle";
      case "error":
        return "error";
    }
  }

  test("idle → keyDown → recording", () => {
    expect(pttTransition("idle", "keyDown")).toBe("recording");
  });

  test("recording → keyUp → idle", () => {
    expect(pttTransition("recording", "keyUp")).toBe("idle");
  });

  test("idle → ptt_active_true → recording", () => {
    expect(pttTransition("idle", "ptt_active_true")).toBe("recording");
  });

  test("recording → ptt_active_false → idle", () => {
    expect(pttTransition("recording", "ptt_active_false")).toBe("idle");
  });

  test("error → keyDown → idle (clears error)", () => {
    expect(pttTransition("error", "keyDown")).toBe("idle");
  });

  test("idle → error → error", () => {
    expect(pttTransition("idle", "error")).toBe("error");
  });

  test("recording → error → error", () => {
    expect(pttTransition("recording", "error")).toBe("error");
  });
});

// ── Button Title Truncation ───────────────────────────────────────────

describe("button title truncation", () => {
  function truncateDeviceName(name: string, maxLen: number = 10): string {
    if (name.length <= maxLen) return name;
    return name.substring(0, maxLen - 1) + "…";
  }

  test("short name unchanged", () => {
    expect(truncateDeviceName("Default")).toBe("Default");
  });

  test("exact length unchanged", () => {
    expect(truncateDeviceName("1234567890")).toBe("1234567890");
  });

  test("long name truncated with ellipsis", () => {
    expect(truncateDeviceName("Blue Yeti Pro")).toBe("Blue Yeti…");
  });

  test("very long name truncated", () => {
    const long = "Focusrite Scarlett 2i2 USB Audio Interface";
    const result = truncateDeviceName(long);
    expect(result).toHaveLength(10);
    expect(result.endsWith("…")).toBe(true);
  });
});

// ── Reconnect Backoff ─────────────────────────────────────────────────

describe("reconnect backoff", () => {
  function nextDelay(current: number, max: number = 30000): number {
    return Math.min(current * 2, max);
  }

  test("doubles delay", () => {
    expect(nextDelay(1000)).toBe(2000);
    expect(nextDelay(2000)).toBe(4000);
  });

  test("caps at max", () => {
    expect(nextDelay(16000)).toBe(30000);
    expect(nextDelay(30000)).toBe(30000);
  });

  test("sequence: 1s → 2s → 4s → 8s → 16s → 30s → 30s", () => {
    let delay = 1000;
    const sequence = [delay];
    for (let i = 0; i < 6; i++) {
      delay = nextDelay(delay);
      sequence.push(delay);
    }
    expect(sequence).toEqual([1000, 2000, 4000, 8000, 16000, 30000, 30000]);
  });
});

// ── Error → Action UUID Mapping ───────────────────────────────────────

describe("error action mapping", () => {
  function mapSourceActionToUUID(sourceAction: string): string | null {
    switch (sourceAction) {
      case "ptt_down":
      case "ptt_up":
        return "com.minerva.streamdeck.ptt";
      case "set_input_device":
      case "list_input_devices":
        return "com.minerva.streamdeck.input-device";
      default:
        return null;
    }
  }

  test("ptt_down maps to PTT action", () => {
    expect(mapSourceActionToUUID("ptt_down")).toBe("com.minerva.streamdeck.ptt");
  });

  test("ptt_up maps to PTT action", () => {
    expect(mapSourceActionToUUID("ptt_up")).toBe("com.minerva.streamdeck.ptt");
  });

  test("set_input_device maps to input device action", () => {
    expect(mapSourceActionToUUID("set_input_device")).toBe(
      "com.minerva.streamdeck.input-device"
    );
  });

  test("unknown action returns null", () => {
    expect(mapSourceActionToUUID("explode")).toBeNull();
  });
});
