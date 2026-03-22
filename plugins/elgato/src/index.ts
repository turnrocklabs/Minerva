/**
 * Minerva Stream Deck Plugin
 *
 * Two WebSocket connections:
 * 1. Upstream: Stream Deck app (Elgato protocol)
 * 2. Downstream: Minerva app (Minerva protocol)
 */

import { parseArgs, createRegistrationMessage } from "./streamdeck-protocol";
import type { SDEvent, SDCommand } from "./streamdeck-protocol";
import type { MinervaCommand, MinervaEvent } from "./minerva-protocol";
import { Icons } from "./icons";
import { friendlyDeviceName } from "./friendly-names";
import { isValidEvent, DEFAULT_PORT } from "./minerva-protocol";

// ── Action UUIDs ──────────────────────────────────────────────────────

const ACTION_PTT = "com.minerva.streamdeck.ptt";
const ACTION_INPUT_DEVICE = "com.minerva.streamdeck.input-device";

// ── State ─────────────────────────────────────────────────────────────

type ActionInstance = {
  context: string;
  action: string;
  device: string;
};

const instances: Map<string, ActionInstance> = new Map();
let sdSocket: WebSocket | null = null;
let minervaSocket: WebSocket | null = null;
let minervaReconnectDelay = 1000;
let minervaConnected = false;

// Minerva state cache
let currentInputDevice = "Default";
let inputDevices: string[] = ["Default"];
let pttActive = false;
let hasError: Map<string, boolean> = new Map(); // context → error state

// ── Stream Deck Connection ────────────────────────────────────────────

function connectStreamDeck(): void {
  const args = parseArgs(process.argv.slice(2));
  const url = `ws://127.0.0.1:${args.port}`;

  sdSocket = new WebSocket(url);

  sdSocket.onopen = () => {
    sdSocket!.send(createRegistrationMessage(args));
    log("Connected to Stream Deck app");
  };

  sdSocket.onmessage = (ev) => {
    try {
      const event: SDEvent = JSON.parse(String(ev.data));
      handleSDEvent(event);
    } catch (e) {
      log(`Failed to parse SD event: ${e}`);
    }
  };

  sdSocket.onclose = () => {
    log("Stream Deck connection closed. Exiting.");
    process.exit(0);
  };

  sdSocket.onerror = (err) => {
    log(`Stream Deck WebSocket error: ${err}`);
  };
}

// ── Stream Deck Event Handling ────────────────────────────────────────

function handleSDEvent(event: SDEvent): void {
  switch (event.event) {
    case "keyDown":
      handleKeyDown(event.action, event.context);
      break;
    case "keyUp":
      handleKeyUp(event.action, event.context);
      break;
    case "willAppear":
      instances.set(event.context, {
        context: event.context,
        action: event.action,
        device: event.device,
      });
      updateButtonImage(event.context, event.action);
      break;
    case "willDisappear":
      instances.delete(event.context);
      break;
    case "didReceiveSettings":
    case "didReceiveGlobalSettings":
      // TODO: handle settings for host/port config
      break;
    case "sendToPlugin":
      // TODO: property inspector messages
      break;
  }
}

function handleKeyDown(action: string, context: string): void {
  // Clear error state on any key press
  if (hasError.get(context)) {
    hasError.set(context, false);
    updateButtonImage(context, action);
    return;
  }

  // If not connected, try reconnecting immediately on button press
  if (!minervaConnected) {
    minervaReconnectDelay = 1000;
    connectMinerva();
    return;
  }

  switch (action) {
    case ACTION_PTT:
      // Toggle PTT: press to start, press again to stop (matches Minerva UI)
      if (pttActive) {
        sendToMinerva({ action: "ptt_up" });
      } else {
        sendToMinerva({ action: "ptt_down" });
      }
      break;
    case ACTION_INPUT_DEVICE:
      cycleInputDevice();
      break;
  }
}

function handleKeyUp(_action: string, _context: string): void {
  // PTT is toggle-based (not hold-to-talk), so keyUp is a no-op
}

function cycleInputDevice(): void {
  if (inputDevices.length <= 1) return;

  const currentIndex = inputDevices.indexOf(currentInputDevice);
  const nextIndex = (currentIndex + 1) % inputDevices.length;
  sendToMinerva({
    action: "set_input_device",
    device: inputDevices[nextIndex],
  });
}

// ── Minerva Connection ────────────────────────────────────────────────

function connectMinerva(): void {
  const host = "127.0.0.1";
  const port = DEFAULT_PORT;
  const url = `ws://${host}:${port}`;

  try {
    minervaSocket = new WebSocket(url);
  } catch {
    scheduleMinervaReconnect();
    return;
  }

  minervaSocket.onopen = () => {
    log("Connected to Minerva");
    minervaConnected = true;
    minervaReconnectDelay = 1000; // reset backoff
    sendToMinerva({ action: "get_state" });
    updateAllButtons();
  };

  minervaSocket.onmessage = (ev) => {
    try {
      const data = JSON.parse(String(ev.data));
      if (isValidEvent(data)) {
        handleMinervaEvent(data);
      }
    } catch (e) {
      log(`Failed to parse Minerva event: ${e}`);
    }
  };

  minervaSocket.onclose = () => {
    log("Minerva connection closed");
    minervaConnected = false;
    minervaSocket = null;
    updateAllButtons(); // show disconnected state
    scheduleMinervaReconnect();
  };

  minervaSocket.onerror = () => {
    // onclose will fire after this
  };
}

function scheduleMinervaReconnect(): void {
  setTimeout(() => {
    connectMinerva();
  }, minervaReconnectDelay);
  minervaReconnectDelay = Math.min(minervaReconnectDelay * 2, 5000); // cap at 5s
}

function sendToMinerva(cmd: MinervaCommand): void {
  if (minervaSocket?.readyState === WebSocket.OPEN) {
    minervaSocket.send(JSON.stringify(cmd));
  }
}

// ── Minerva Event Handling ────────────────────────────────────────────

function handleMinervaEvent(event: MinervaEvent): void {
  switch (event.event) {
    case "state":
      currentInputDevice = event.input_device;
      inputDevices = event.input_devices;
      pttActive = event.ptt_active;
      updateAllButtons();
      break;

    case "input_device_changed":
      currentInputDevice = event.device;
      inputDevices = event.devices;
      updateButtonsByAction(ACTION_INPUT_DEVICE);
      break;

    case "ptt_active":
      pttActive = event.active;
      updateButtonsByAction(ACTION_PTT);
      break;

    case "engagement_changed":
      // Future use
      break;

    case "error":
      // Show error on buttons matching the failed action
      const errorAction = mapSourceActionToUUID(event.source_action);
      if (errorAction) {
        for (const [context, inst] of instances) {
          if (inst.action === errorAction) {
            hasError.set(context, true);
            sendShowAlert(context);
            updateButtonImage(context, inst.action);
          }
        }
      }
      log(`Minerva error [${event.source_action}]: ${event.message}`);
      break;
  }
}

function mapSourceActionToUUID(sourceAction: string): string | null {
  switch (sourceAction) {
    case "ptt_down":
    case "ptt_up":
      return ACTION_PTT;
    case "set_input_device":
    case "list_input_devices":
      return ACTION_INPUT_DEVICE;
    default:
      return null;
  }
}

// ── Button Updates ────────────────────────────────────────────────────

function updateAllButtons(): void {
  for (const [context, inst] of instances) {
    updateButtonImage(context, inst.action);
  }
}

function updateButtonsByAction(action: string): void {
  for (const [context, inst] of instances) {
    if (inst.action === action) {
      updateButtonImage(context, inst.action);
    }
  }
}

function updateButtonImage(context: string, action: string): void {
  if (!minervaConnected) {
    sendSetImage(context, ""); // reset to default icon
    sendSetTitle(context, "Offline");
    return;
  }

  if (hasError.get(context)) {
    sendShowAlert(context);
    sendSetTitle(context, "Error");
    return;
  }

  switch (action) {
    case ACTION_PTT:
      sendSetImage(context, pttActive ? Icons.pttActive : Icons.pttIdle);
      sendSetTitle(context, pttActive ? "REC" : "");
      break;

    case ACTION_INPUT_DEVICE: {
      sendSetImage(context, Icons.inputDevice);
      sendSetTitle(context, friendlyDeviceName(currentInputDevice));
      break;
    }
  }
}

// ── Stream Deck Commands ──────────────────────────────────────────────

function sendSetTitle(context: string, title: string): void {
  sendToSD({
    context,
    event: "setTitle",
    payload: { title, target: 0 },
  });
}

function sendSetImage(context: string, image: string): void {
  sendToSD({
    context,
    event: "setImage",
    payload: { image, target: 0 },
  });
}

function sendShowAlert(context: string): void {
  sendToSD({ context, event: "showAlert" });
}

function sendToSD(cmd: SDCommand): void {
  if (sdSocket?.readyState === WebSocket.OPEN) {
    sdSocket.send(JSON.stringify(cmd));
  }
}

function log(message: string): void {
  const ts = new Date().toISOString();
  console.error(`[minerva-plugin] ${ts} ${message}`);

  // Also log to Stream Deck
  sendToSD({
    event: "logMessage",
    payload: { message: `[Minerva] ${message}` },
  } as any);
}

// ── Main ──────────────────────────────────────────────────────────────

connectStreamDeck();
connectMinerva();
