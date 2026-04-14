import { describe, test, expect } from "bun:test";
import {
  isValidCommand,
  isValidEvent,
  PROTOCOL_VERSION,
  type MinervaCommand,
  type MinervaEvent,
} from "../src/minerva-protocol";

// ── Test Fixtures ─────────────────────────────────────────────────────

const VALID_COMMANDS: { name: string; msg: MinervaCommand }[] = [
  { name: "ptt_down", msg: { action: "ptt_down" } },
  { name: "ptt_up", msg: { action: "ptt_up" } },
  { name: "list_input_devices", msg: { action: "list_input_devices" } },
  { name: "get_state", msg: { action: "get_state" } },
  {
    name: "set_input_device",
    msg: { action: "set_input_device", device: "Blue Yeti" },
  },
  { name: "clear_input", msg: { action: "clear_input" } },
  { name: "submit_chat", msg: { action: "submit_chat" } },
  {
    name: "set_output_device",
    msg: { action: "set_output_device", device: "Headphones" },
  },
];

const VALID_EVENTS: { name: string; msg: MinervaEvent }[] = [
  {
    name: "state",
    msg: {
      event: "state",
      protocol_version: PROTOCOL_VERSION,
      input_device: "Default",
      input_devices: ["Default", "Blue Yeti", "Webcam Mic"],
      output_device: "Speakers",
      output_devices: ["Speakers", "Headphones"],
      ptt_active: false,
      engagement: "STANDBY",
    },
  },
  {
    name: "input_device_changed",
    msg: {
      event: "input_device_changed",
      device: "Blue Yeti",
      devices: ["Default", "Blue Yeti", "Webcam Mic"],
    },
  },
  {
    name: "output_device_changed",
    msg: {
      event: "output_device_changed",
      device: "Headphones",
      devices: ["Speakers", "Headphones"],
    },
  },
  {
    name: "ptt_active true",
    msg: { event: "ptt_active", active: true },
  },
  {
    name: "ptt_active false",
    msg: { event: "ptt_active", active: false },
  },
  {
    name: "engagement_changed",
    msg: { event: "engagement_changed", state: "ENGAGED" },
  },
  {
    name: "error",
    msg: {
      event: "error",
      source_action: "ptt_down",
      message: "No active chat open",
    },
  },
];

// ── Command Validation ────────────────────────────────────────────────

describe("isValidCommand", () => {
  for (const { name, msg } of VALID_COMMANDS) {
    test(`accepts valid command: ${name}`, () => {
      expect(isValidCommand(msg)).toBe(true);
    });
  }

  test("rejects null", () => {
    expect(isValidCommand(null)).toBe(false);
  });

  test("rejects non-object", () => {
    expect(isValidCommand("ptt_down")).toBe(false);
  });

  test("rejects missing action", () => {
    expect(isValidCommand({})).toBe(false);
  });

  test("rejects unknown action", () => {
    expect(isValidCommand({ action: "explode" })).toBe(false);
  });

  test("rejects set_input_device without device", () => {
    expect(isValidCommand({ action: "set_input_device" })).toBe(false);
  });

  test("rejects set_input_device with empty device", () => {
    expect(
      isValidCommand({ action: "set_input_device", device: "" })
    ).toBe(false);
  });

  test("rejects set_input_device with non-string device", () => {
    expect(
      isValidCommand({ action: "set_input_device", device: 42 })
    ).toBe(false);
  });

  test("rejects set_output_device without device", () => {
    expect(isValidCommand({ action: "set_output_device" })).toBe(false);
  });

  test("rejects set_output_device with empty device", () => {
    expect(
      isValidCommand({ action: "set_output_device", device: "" })
    ).toBe(false);
  });
});

// ── Event Validation ──────────────────────────────────────────────────

describe("isValidEvent", () => {
  for (const { name, msg } of VALID_EVENTS) {
    test(`accepts valid event: ${name}`, () => {
      expect(isValidEvent(msg)).toBe(true);
    });
  }

  test("rejects null", () => {
    expect(isValidEvent(null)).toBe(false);
  });

  test("rejects missing event field", () => {
    expect(isValidEvent({ active: true })).toBe(false);
  });

  test("rejects unknown event type", () => {
    expect(isValidEvent({ event: "self_destruct" })).toBe(false);
  });

  test("rejects state event missing protocol_version", () => {
    expect(
      isValidEvent({
        event: "state",
        input_device: "Default",
        input_devices: [],
        ptt_active: false,
        engagement: "STANDBY",
      })
    ).toBe(false);
  });

  test("rejects state event with wrong ptt_active type", () => {
    expect(
      isValidEvent({
        event: "state",
        protocol_version: 1,
        input_device: "Default",
        input_devices: [],
        ptt_active: "no",
        engagement: "STANDBY",
      })
    ).toBe(false);
  });

  test("rejects input_device_changed missing devices array", () => {
    expect(
      isValidEvent({ event: "input_device_changed", device: "Mic" })
    ).toBe(false);
  });

  test("rejects error missing message", () => {
    expect(
      isValidEvent({ event: "error", source_action: "ptt_down" })
    ).toBe(false);
  });
});

// ── Round-trip (serialize → parse → validate) ─────────────────────────

describe("round-trip serialization", () => {
  for (const { name, msg } of VALID_COMMANDS) {
    test(`command round-trips: ${name}`, () => {
      const json = JSON.stringify(msg);
      const parsed = JSON.parse(json);
      expect(isValidCommand(parsed)).toBe(true);
    });
  }

  for (const { name, msg } of VALID_EVENTS) {
    test(`event round-trips: ${name}`, () => {
      const json = JSON.stringify(msg);
      const parsed = JSON.parse(json);
      expect(isValidEvent(parsed)).toBe(true);
    });
  }
});
