import { describe, test, expect } from "bun:test";
import { friendlyDeviceName } from "../src/friendly-names";

describe("friendlyDeviceName", () => {
  test("Default passthrough", () => {
    expect(friendlyDeviceName("Default")).toBe("Default");
  });

  test("empty string", () => {
    expect(friendlyDeviceName("")).toBe("Default");
  });

  // Actual device names — now with 2-line wrapping (maxLen=12 per line)
  test("Sennheiser SP 20 — fits on two lines", () => {
    const result = friendlyDeviceName("alsa_input.usb-1395_Sennheiser_SP_20-00.mono-fallback");
    expect(result).toBe("Sennheiser\nSP 20");
  });

  test("Sennheiser Profile — brand + model on two lines", () => {
    const result = friendlyDeviceName("alsa_input.usb-Sennheiser_Sennheiser_Profile_0225055113-00.mono-fallback");
    expect(result).toBe("Sennheiser\nProfile");
  });

  test("Logitech BRIO — fits on two lines", () => {
    const result = friendlyDeviceName("alsa_input.usb-046d_Logitech_BRIO_2CF759D4-03.iec958-stereo");
    expect(result).toBe("Logitech\nBRIO");
  });

  test("Plantronics BT600 — two lines", () => {
    const result = friendlyDeviceName("alsa_input.usb-Plantronics_Plantronics_BT600_b396c3ee30880d4e8f71f6d6fb9d20cc-00.mono-fallback");
    expect(result).toBe("Plantronics\nBT600");
  });

  test("Generic USB Audio — short enough for one line", () => {
    const result = friendlyDeviceName("alsa_input.usb-Generic_USB_Audio-00.analog-stereo");
    expect(result).toBe("Generic");
  });

  test("Onboard/PCI audio — two lines", () => {
    const result = friendlyDeviceName("alsa_input.pci-0000_0c_00.4.analog-stereo");
    expect(result).toBe("Onboard\nAudio");
  });

  test("Sonix USB Camera — short enough for one line", () => {
    const result = friendlyDeviceName("alsa_input.usb-Sonix_Technology_Co.__Ltd_USB_2.0_Camera_SN0001-02.mono-fallback");
    expect(result).toBe("Sonix");
  });

  test("Output: USB SPDIF — two lines", () => {
    const result = friendlyDeviceName("alsa_output.usb-Generic_USB_SPDIF_Adapter_202110200032-00.iec958-stereo");
    expect(result).toBe("Generic USB\nSPDIF");
  });

  test("Monitor source stripped", () => {
    const result = friendlyDeviceName("alsa_output.usb-1395_Sennheiser_SP_20-00.analog-stereo.monitor");
    expect(result).toBe("Sennheiser\nSP 20");
  });
});
