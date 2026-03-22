/**
 * Parse PulseAudio/PipeWire device names into short friendly display names.
 *
 * Input:  "alsa_input.usb-Sennheiser_Sennheiser_Profile_0225055113-00.mono-fallback"
 * Output: "Sennheiser Profile"
 *
 * Input:  "alsa_input.usb-046d_Logitech_BRIO_2CF759D4-03.iec958-stereo"
 * Output: "Logitech BRIO"
 */

// Known brand names to clean up duplicates like "Sennheiser_Sennheiser_Profile"
const BRANDS = [
  "Sennheiser", "Plantronics", "Logitech", "Blue", "Rode", "Shure",
  "Audio-Technica", "HyperX", "Corsair", "Razer", "JBL", "Jabra",
  "Focusrite", "PreSonus", "Behringer", "Mackie", "Elgato", "Generic",
  "Sonix", "Realtek",
];

export function friendlyDeviceName(raw: string, maxLen: number = 12): string {
  if (!raw || raw === "Default") return "Default";

  let name = raw;

  // Strip alsa_input./alsa_output. prefix
  name = name.replace(/^alsa_(input|output)\./, "");

  // Strip .monitor suffix
  name = name.replace(/\.monitor$/, "");

  // Strip audio format suffix (.analog-stereo, .mono-fallback, .iec958-stereo, etc.)
  name = name.replace(/\.(analog-stereo|mono-fallback|iec958-stereo|analog-mono|surround-\S+)$/, "");

  // Handle PCI devices: pci-ADDR
  if (/^pci-/.test(name)) {
    return twoLineWrap("Onboard Audio", maxLen);
  }

  // Handle USB devices: usb-VENDOR_PRODUCT_SERIAL-NN
  const usbMatch = name.match(/^usb-(.+?)(?:-[\da-f]{2})$/);
  if (usbMatch) {
    name = usbMatch[1];
  } else {
    name = name.replace(/^usb-/, "");
  }

  // Replace underscores with spaces
  name = name.replace(/_/g, " ");

  // Remove long hex serial numbers (8+ hex chars)
  name = name.replace(/\b[0-9a-f]{8,}\b/gi, "").trim();

  // Remove numeric/hex vendor IDs at the start (e.g., "1395 Sennheiser", "046d Logitech")
  name = name.replace(/^[0-9a-f]{3,6}\s+/i, "");

  // Remove duplicate brand names ("Sennheiser Sennheiser Profile" → "Sennheiser Profile")
  for (const brand of BRANDS) {
    const pattern = new RegExp(`${brand}\\s+${brand}`, "i");
    name = name.replace(pattern, brand);
  }

  // Remove corporate suffixes: "Technology Co. Ltd", "Co.  Ltd", etc.
  name = name.replace(/\s+Technology\s+Co\.?\s*,?\s*Ltd\.?/i, "");
  name = name.replace(/\s+Co\.?\s+Ltd\b/i, "");

  // Remove "USB 2.0 Camera" / "USB Audio" and similar generic suffixes
  name = name.replace(/\s+USB\s+\d+\.\d+\s+Camera\b.*/i, "");
  name = name.replace(/\s+USB\s+Audio$/i, "");
  name = name.replace(/\s+USB\s+SPDIF\s+Adapter\b/i, " USB SPDIF");

  // Remove short serial numbers (SN + digits, or trailing lone alphanumeric tokens)
  name = name.replace(/\s+SN\d+$/i, "");

  // Remove "Stereo Microphone" if name is still long
  if (name.length > maxLen) {
    name = name.replace(/\s+Stereo\s+Microphone$/i, "");
  }

  // Clean up extra spaces
  name = name.replace(/\s{2,}/g, " ").trim();

  return twoLineWrap(name, maxLen);
}

function twoLineWrap(s: string, lineLen: number): string {
  if (s.length <= lineLen) return s;

  // Try to split at a word boundary near the middle
  const words = s.split(" ");
  if (words.length >= 2) {
    let line1 = words[0];
    let line2Idx = 1;
    // Fill line 1 with words that fit
    for (let i = 1; i < words.length; i++) {
      const candidate = line1 + " " + words[i];
      if (candidate.length <= lineLen) {
        line1 = candidate;
        line2Idx = i + 1;
      } else {
        break;
      }
    }
    const line2 = words.slice(line2Idx).join(" ");
    if (line2) {
      return line1 + "\n" + truncate(line2, lineLen);
    }
  }

  // Single long word — just truncate
  return truncate(s, lineLen);
}

function truncate(s: string, maxLen: number): string {
  if (s.length <= maxLen) return s;
  return s.substring(0, maxLen - 1).trimEnd() + "…";
}
