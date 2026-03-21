/**
 * Elgato Stream Deck WebSocket Protocol types
 *
 * Implements the subset of the Elgato SDK protocol needed for v1.
 * Source: docs.elgato.com/streamdeck/sdk/references/websocket/plugin/
 */

// ── CLI Args ──────────────────────────────────────────────────────────

export type StreamDeckArgs = {
  port: number;
  pluginUUID: string;
  registerEvent: string;
  info: RegistrationInfo;
};

export type RegistrationInfo = {
  application: {
    font: string;
    language: string;
    platform: string;
    platformVersion: string;
    version: string;
  };
  devices: {
    id: string;
    name: string;
    size: { columns: number; rows: number };
    type: number;
  }[];
  plugin: { uuid: string; version: string };
};

// ── Events Received ───────────────────────────────────────────────────

export type SDEvent =
  | SDKeyDownEvent
  | SDKeyUpEvent
  | SDWillAppearEvent
  | SDWillDisappearEvent
  | SDDidReceiveSettingsEvent
  | SDDidReceiveGlobalSettingsEvent
  | SDSendToPluginEvent;

export type SDKeyDownEvent = {
  action: string;
  context: string;
  device: string;
  event: "keyDown";
  payload: SDKeyPayload;
};

export type SDKeyUpEvent = {
  action: string;
  context: string;
  device: string;
  event: "keyUp";
  payload: SDKeyPayload;
};

export type SDKeyPayload = {
  controller: "Keypad" | "Encoder";
  coordinates: { column: number; row: number };
  isInMultiAction: boolean;
  resources: Record<string, string>;
  settings: Record<string, unknown>;
  state?: number;
};

export type SDWillAppearEvent = {
  action: string;
  context: string;
  device: string;
  event: "willAppear";
  payload: SDKeyPayload;
};

export type SDWillDisappearEvent = {
  action: string;
  context: string;
  device: string;
  event: "willDisappear";
  payload: SDKeyPayload;
};

export type SDDidReceiveSettingsEvent = {
  action: string;
  context: string;
  device: string;
  event: "didReceiveSettings";
  id?: string;
  payload: SDKeyPayload;
};

export type SDDidReceiveGlobalSettingsEvent = {
  event: "didReceiveGlobalSettings";
  id?: string;
  payload: { settings: Record<string, unknown> };
};

export type SDSendToPluginEvent = {
  action: string;
  context: string;
  event: "sendToPlugin";
  payload: unknown;
};

// ── Commands Sent ─────────────────────────────────────────────────────

export type SDCommand =
  | SDSetImageCommand
  | SDSetTitleCommand
  | SDSetSettingsCommand
  | SDSetGlobalSettingsCommand
  | SDShowAlertCommand
  | SDShowOkCommand
  | SDLogMessageCommand
  | SDGetSettingsCommand
  | SDGetGlobalSettingsCommand
  | SDSendToPropertyInspectorCommand;

export type SDSetImageCommand = {
  context: string;
  event: "setImage";
  payload: { image?: string; target?: number; state?: number };
};

export type SDSetTitleCommand = {
  context: string;
  event: "setTitle";
  payload: { title?: string; target?: number; state?: number };
};

export type SDSetSettingsCommand = {
  context: string;
  event: "setSettings";
  payload: Record<string, unknown>;
};

export type SDSetGlobalSettingsCommand = {
  context: string;
  event: "setGlobalSettings";
  payload: Record<string, unknown>;
};

export type SDShowAlertCommand = {
  context: string;
  event: "showAlert";
};

export type SDShowOkCommand = {
  context: string;
  event: "showOk";
};

export type SDLogMessageCommand = {
  event: "logMessage";
  payload: { message: string };
};

export type SDGetSettingsCommand = {
  context: string;
  event: "getSettings";
  id?: string;
};

export type SDGetGlobalSettingsCommand = {
  context: string;
  event: "getGlobalSettings";
  id?: string;
};

export type SDSendToPropertyInspectorCommand = {
  context: string;
  event: "sendToPropertyInspector";
  payload: unknown;
};

// ── Target Enum ───────────────────────────────────────────────────────

export const Target = {
  HardwareAndSoftware: 0,
  Hardware: 1,
  Software: 2,
} as const;

// ── CLI Arg Parsing ───────────────────────────────────────────────────

export function parseArgs(argv: string[]): StreamDeckArgs {
  let port = 0;
  let pluginUUID = "";
  let registerEvent = "";
  let info: RegistrationInfo | undefined;

  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case "-port":
        port = parseInt(argv[++i], 10);
        break;
      case "-pluginUUID":
        pluginUUID = argv[++i];
        break;
      case "-registerEvent":
        registerEvent = argv[++i];
        break;
      case "-info":
        info = JSON.parse(argv[++i]);
        break;
    }
  }

  if (!port || !pluginUUID || !registerEvent || !info) {
    throw new Error(
      `Missing required args. Got: port=${port}, uuid=${pluginUUID}, event=${registerEvent}, info=${!!info}`
    );
  }

  return { port, pluginUUID, registerEvent, info };
}

// ── Registration ──────────────────────────────────────────────────────

export function createRegistrationMessage(
  args: StreamDeckArgs
): string {
  return JSON.stringify({
    event: args.registerEvent,
    uuid: args.pluginUUID,
  });
}
