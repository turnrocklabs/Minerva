/**
 * Minerva ↔ Stream Deck Plugin WebSocket Protocol
 *
 * This file defines the wire format for the Minerva control channel.
 * The plugin connects to Minerva at ws://localhost:{port} and exchanges
 * JSON messages. Minerva pushes state changes; plugin sends commands.
 */

// ── Protocol Version ──────────────────────────────────────────────────

export const PROTOCOL_VERSION = 1;
export const DEFAULT_PORT = 7778;

// ── Commands (Plugin → Minerva) ───────────────────────────────────────

export type MinervaCommand =
  | { action: "ptt_down" }
  | { action: "ptt_up" }
  | { action: "list_input_devices" }
  | { action: "set_input_device"; device: string }
  | { action: "get_state" };

export type MinervaCommandAction = MinervaCommand["action"];

// ── Events (Minerva → Plugin) ─────────────────────────────────────────

export type MinervaEvent =
  | MinervaStateEvent
  | MinervaInputDeviceChangedEvent
  | MinervaPttActiveEvent
  | MinervaEngagementChangedEvent
  | MinervaErrorEvent;

export type MinervaStateEvent = {
  event: "state";
  protocol_version: number;
  input_device: string;
  input_devices: string[];
  ptt_active: boolean;
  engagement: string; // "STANDBY" | "ENGAGED"
};

export type MinervaInputDeviceChangedEvent = {
  event: "input_device_changed";
  device: string;
  devices: string[];
};

export type MinervaPttActiveEvent = {
  event: "ptt_active";
  active: boolean;
};

export type MinervaEngagementChangedEvent = {
  event: "engagement_changed";
  state: string; // "STANDBY" | "ENGAGED"
};

export type MinervaErrorEvent = {
  event: "error";
  source_action: string;
  message: string;
};

export type MinervaEventType = MinervaEvent["event"];

// ── Helpers ───────────────────────────────────────────────────────────

export function isValidCommand(data: unknown): data is MinervaCommand {
  if (typeof data !== "object" || data === null) return false;
  const obj = data as Record<string, unknown>;
  if (typeof obj.action !== "string") return false;

  switch (obj.action) {
    case "ptt_down":
    case "ptt_up":
    case "list_input_devices":
    case "get_state":
      return true;
    case "set_input_device":
      return typeof obj.device === "string" && obj.device.length > 0;
    default:
      return false;
  }
}

export function isValidEvent(data: unknown): data is MinervaEvent {
  if (typeof data !== "object" || data === null) return false;
  const obj = data as Record<string, unknown>;
  if (typeof obj.event !== "string") return false;

  switch (obj.event) {
    case "state":
      return (
        typeof obj.protocol_version === "number" &&
        typeof obj.input_device === "string" &&
        Array.isArray(obj.input_devices) &&
        typeof obj.ptt_active === "boolean" &&
        typeof obj.engagement === "string"
      );
    case "input_device_changed":
      return typeof obj.device === "string" && Array.isArray(obj.devices);
    case "ptt_active":
      return typeof obj.active === "boolean";
    case "engagement_changed":
      return typeof obj.state === "string";
    case "error":
      return (
        typeof obj.source_action === "string" &&
        typeof obj.message === "string"
      );
    default:
      return false;
  }
}
