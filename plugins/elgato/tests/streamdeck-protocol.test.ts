import { describe, test, expect } from "bun:test";
import {
  parseArgs,
  createRegistrationMessage,
  type StreamDeckArgs,
} from "../src/streamdeck-protocol";

const SAMPLE_INFO = JSON.stringify({
  application: {
    font: "Arial",
    language: "en",
    platform: "linux",
    platformVersion: "6.8",
    version: "1.0.0",
  },
  devices: [
    {
      id: "device-1",
      name: "Stream Deck MK.2",
      size: { columns: 5, rows: 3 },
      type: 0,
    },
  ],
  plugin: { uuid: "com.minerva.streamdeck", version: "1.0.0" },
});

// ── parseArgs ─────────────────────────────────────────────────────────

describe("parseArgs", () => {
  test("parses valid args", () => {
    const args = parseArgs([
      "-port",
      "28196",
      "-pluginUUID",
      "com.minerva.streamdeck",
      "-registerEvent",
      "registerPlugin",
      "-info",
      SAMPLE_INFO,
    ]);

    expect(args.port).toBe(28196);
    expect(args.pluginUUID).toBe("com.minerva.streamdeck");
    expect(args.registerEvent).toBe("registerPlugin");
    expect(args.info.devices).toHaveLength(1);
    expect(args.info.devices[0].name).toBe("Stream Deck MK.2");
  });

  test("handles args in any order", () => {
    const args = parseArgs([
      "-registerEvent",
      "registerPlugin",
      "-info",
      SAMPLE_INFO,
      "-pluginUUID",
      "com.minerva.streamdeck",
      "-port",
      "12345",
    ]);

    expect(args.port).toBe(12345);
    expect(args.pluginUUID).toBe("com.minerva.streamdeck");
  });

  test("throws on missing port", () => {
    expect(() =>
      parseArgs([
        "-pluginUUID",
        "uuid",
        "-registerEvent",
        "reg",
        "-info",
        SAMPLE_INFO,
      ])
    ).toThrow("Missing required args");
  });

  test("throws on missing pluginUUID", () => {
    expect(() =>
      parseArgs([
        "-port",
        "1234",
        "-registerEvent",
        "reg",
        "-info",
        SAMPLE_INFO,
      ])
    ).toThrow("Missing required args");
  });

  test("throws on missing registerEvent", () => {
    expect(() =>
      parseArgs([
        "-port",
        "1234",
        "-pluginUUID",
        "uuid",
        "-info",
        SAMPLE_INFO,
      ])
    ).toThrow("Missing required args");
  });

  test("throws on missing info", () => {
    expect(() =>
      parseArgs([
        "-port",
        "1234",
        "-pluginUUID",
        "uuid",
        "-registerEvent",
        "reg",
      ])
    ).toThrow("Missing required args");
  });

  test("throws on empty argv", () => {
    expect(() => parseArgs([])).toThrow("Missing required args");
  });

  test("ignores unknown flags", () => {
    const args = parseArgs([
      "-port",
      "28196",
      "-pluginUUID",
      "com.minerva.streamdeck",
      "-registerEvent",
      "registerPlugin",
      "-info",
      SAMPLE_INFO,
      "-unknown",
      "value",
    ]);

    expect(args.port).toBe(28196);
  });
});

// ── createRegistrationMessage ─────────────────────────────────────────

describe("createRegistrationMessage", () => {
  test("creates correct registration JSON", () => {
    const args: StreamDeckArgs = {
      port: 28196,
      pluginUUID: "com.minerva.streamdeck",
      registerEvent: "registerPlugin",
      info: JSON.parse(SAMPLE_INFO),
    };

    const msg = JSON.parse(createRegistrationMessage(args));
    expect(msg.event).toBe("registerPlugin");
    expect(msg.uuid).toBe("com.minerva.streamdeck");
    expect(Object.keys(msg)).toEqual(["event", "uuid"]);
  });
});
