// Settings for the lock idle face, persisted next to the other Omarchy config.
// The lock plugin reads this file directly (plugins cannot import each other),
// so its shape is the contract between the two.

var DEFAULTS = {
  background: "",        // "" = follow the session background
  blur: 64,              // 0-128
  showWeather: true,
  showDate: true,
  showBattery: true,
  showNetwork: true,
  showHint: true,
  // Which display carries the lock interface:
  //   "internal" — the laptop panel when the lid is open, else the focused one
  //   "focused"  — whichever screen was focused when locking
  //   "all"      — every screen, as the stock lock screen does
  lockDisplay: "internal",
  // Where the lock goes when the preferred display is not available — a shut
  // lid, or an undocked monitor. "focused" follows the active screen; a
  // monitor description pins it to one display. Descriptions survive a replug;
  // connector names like DP-5 shuffle on a dock.
  lockFallback: "focused",
  // Auth methods. Fingerprint and face are only offered when the system is
  // actually set up for them; these toggles gate the lock screen's use of
  // what exists, they do not enroll anything.
  fingerprintEnabled: true,
  faceEnabled: false,
  // Arm on the first keypress rather than immediately at lock time. Arming at
  // lock starts a verify moments before suspend, which wedges single-client
  // readers; leave this on unless the reader is known to tolerate it.
  armOnInput: true
};

function normalize(raw) {
  var out = {};
  for (var k in DEFAULTS) out[k] = DEFAULTS[k];
  if (!raw || typeof raw !== "object") return out;
  if (typeof raw.background === "string") out.background = raw.background;
  var blur = parseInt(raw.blur);
  if (!isNaN(blur)) out.blur = Math.max(0, Math.min(128, blur));
  if (typeof raw.showWeather === "boolean") out.showWeather = raw.showWeather;
  if (typeof raw.showDate === "boolean") out.showDate = raw.showDate;
  if (typeof raw.showBattery === "boolean") out.showBattery = raw.showBattery;
  if (typeof raw.showNetwork === "boolean") out.showNetwork = raw.showNetwork;
  if (typeof raw.showHint === "boolean") out.showHint = raw.showHint;
  if (raw.lockDisplay === "internal" || raw.lockDisplay === "focused"
      || raw.lockDisplay === "all")
    out.lockDisplay = raw.lockDisplay;
  if (typeof raw.lockFallback === "string") out.lockFallback = raw.lockFallback;
  if (typeof raw.fingerprintEnabled === "boolean") out.fingerprintEnabled = raw.fingerprintEnabled;
  if (typeof raw.faceEnabled === "boolean") out.faceEnabled = raw.faceEnabled;
  if (typeof raw.armOnInput === "boolean") out.armOnInput = raw.armOnInput;
  return out;
}

function parse(text) {
  try {
    return normalize(JSON.parse(String(text || "")));
  } catch (e) {
    return normalize(null);
  }
}
