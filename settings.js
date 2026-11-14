// Adds or removes lidless hooks in Claude Code's settings.json, and can turn on
// Remote Control for every session. Runs on the JavaScript engine built into
// macOS, so there is nothing to install:
//
//   osascript -l JavaScript settings.js <add|remove|status|remote> <settings.json> <lidless.sh>
//
// Only hooks whose command points at lidless.sh are touched. Every other
// setting and hook in the file is written back unchanged.

ObjC.import("Foundation");

// Which Claude Code hook tells lidless what.
var HOOKS = {
  SessionStart: "start",     // new session: stay reachable for the grace period
  UserPromptSubmit: "busy",  // Claude is working on a prompt (from the Mac or the phone)
  Stop: "done",              // Claude finished its turn: grace period starts
  SessionEnd: "end",         // session closed
};

function readFile(path) {
  var fm = $.NSFileManager.defaultManager;
  if (!fm.fileExistsAtPath(path)) return null;
  var text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return ObjC.unwrap(text);
}

function writeFile(path, text) {
  var dir = $(path).stringByDeletingLastPathComponent;
  $.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, $(), null);
  var ok = $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
  if (!ok) throw new Error("Could not write " + path);
}

function shellQuote(s) {
  return "'" + s.replace(/'/g, "'\\''") + "'";
}

function isOurs(hook, script) {
  return !!hook && typeof hook.command === "string" && hook.command.indexOf(script) !== -1;
}

function strip(settings, script) {
  if (!settings.hooks) return;
  Object.keys(HOOKS).forEach(function (name) {
    var groups = settings.hooks[name];
    if (!Array.isArray(groups)) return;
    var kept = [];
    groups.forEach(function (group) {
      if (!group || !Array.isArray(group.hooks)) return kept.push(group);
      var before = group.hooks.length;
      group.hooks = group.hooks.filter(function (h) { return !isOurs(h, script); });
      if (group.hooks.length > 0 || before === 0) kept.push(group);
    });
    if (kept.length) settings.hooks[name] = kept;
    else delete settings.hooks[name];
  });
  if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
}

function add(settings, script) {
  strip(settings, script);
  settings.hooks = settings.hooks || {};
  Object.keys(HOOKS).forEach(function (name) {
    settings.hooks[name] = settings.hooks[name] || [];
    settings.hooks[name].push({
      hooks: [{
        type: "command",
        command: shellQuote(script) + " hook " + HOOKS[name],
        async: true,
      }],
    });
  });
}

function hooksOn(settings, script) {
  return Object.keys(HOOKS).every(function (name) {
    var groups = (settings.hooks && settings.hooks[name]) || [];
    return groups.some(function (g) {
      return g && Array.isArray(g.hooks) && g.hooks.some(function (h) { return isOurs(h, script); });
    });
  });
}

function run(argv) {
  var action = argv[0], path = argv[1], script = argv[2];
  var raw = readFile(path);
  var settings = {};
  if (raw !== null && raw.trim() !== "") {
    try {
      settings = JSON.parse(raw);
    } catch (e) {
      throw new Error(path + " is not valid JSON, so it was left untouched. Fix it and run this again.");
    }
  }
  if (settings === null || typeof settings !== "object" || Array.isArray(settings)) {
    throw new Error(path + " does not contain a JSON object, so it was left untouched.");
  }

  if (action === "status") {
    var rc = settings.remoteControlAtStartup;
    return [
      "Hooks      " + (hooksOn(settings, script) ? "on" : "off (run the installer again)"),
      "Phone      " + (rc === true
        ? "every terminal session connects to Remote Control"
        : "Remote Control is not on for every session"),
    ].join("\n");
  }

  if (action === "add") add(settings, script);
  else if (action === "remove") { if (raw === null) return "Nothing to remove."; strip(settings, script); }
  else if (action === "remote") settings.remoteControlAtStartup = true;
  else throw new Error("Unknown action: " + action);

  var out = JSON.stringify(settings, null, 2) + "\n";
  if (raw !== null && out !== raw) writeFile(path + ".lidless-backup", raw);
  writeFile(path, out);
  return {
    add: "Hooks on.",
    remove: "Hooks off.",
    remote: "Remote Control on for every session.",
  }[action];
}
