"use strict";

const $ = (id) => document.getElementById(id);
const linkKey = location.hash.slice(1);
const headers = /^[A-Za-z0-9_-]{43}$/.test(linkKey) ? { Authorization: "Bearer " + linkKey } : {};
const number = new Intl.NumberFormat("en-US");
const states = {
  checking: ["Checking", "idle"],
  idle: ["Idle", "idle"],
  working: ["Working", "working"],
  resting: ["Resting", "resting"],
  paused: ["Paused", "paused"],
  offline: ["Offline", "offline"],
};

function text(id, value) {
  if ($(id).textContent !== value) $(id).textContent = value;
}

function element(tag, className, label = "") {
  const node = document.createElement(tag);
  node.className = className;
  node.textContent = label;
  return node;
}

function status(state, gateway) {
  const [label, icon] = states[state] ?? states.checking;
  $("status_header").dataset.state = state;
  $("status_icon").className = "icon " + icon;
  text("state", label);
  text("gateway", gateway);
}

function duration(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) return s + " s";
  if (s < 3600) return Math.floor(s / 60) + " min";
  if (s < 86400) return Math.floor(s / 3600) + " h " + Math.floor(s / 60 % 60) + " min";
  return Math.floor(s / 86400) + " d " + Math.floor(s / 3600 % 24) + " h";
}

function memory(bytes) {
  if (!Number.isFinite(bytes)) return "—";
  const gb = bytes / 2 ** 30;
  return gb >= 1 ? gb.toFixed(gb >= 10 ? 0 : 1) + " GB" : Math.round(bytes / 2 ** 20) + " MB";
}

function tokens(count) {
  if (count >= 1000) return (count / 1000).toFixed(count >= 100000 ? 0 : 1) + "K";
  return number.format(count);
}

function meter(id, fraction, color = "--blue") {
  const bar = $(id).firstElementChild;
  bar.style.width = (100 * Math.min(1, Math.max(0, fraction))) + "%";
  bar.style.setProperty("--bar", "var(" + color + ")");
}

function infoRow(icon, label, trailing = "", color = "muted") {
  const row = element("div", "info_row");
  const glyph = element("span", "icon " + icon + " " + color);
  glyph.setAttribute("aria-hidden", "true");
  row.append(glyph, element("span", "row_name", label));
  if (trailing) row.append(element("span", "tail", trailing));
  return row;
}

function dateLabel(at, reference, zone) {
  const clock = new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit", timeZone: zone });
  if (new Intl.DateTimeFormat("en-GB", { timeZone: zone }).format(at) ===
      new Intl.DateTimeFormat("en-GB", { timeZone: zone }).format(reference)) return clock.format(at);
  return new Intl.DateTimeFormat("en-GB", {
    day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: zone,
  }).format(at).replace(",", " ·");
}

function renderActivity(sample) {
  const rows = [];
  const { jobs, model, gateway, sampledAtMs, timezone } = sample;
  if (!gateway.live) {
    rows.push(infoRow("offline", "Gateway offline", "", "red"));
  } else {
    for (const job of jobs.running) rows.push(infoRow("running", job.name, duration(job.runningSeconds), "blue"));
    if (model.activeRequests > 0) {
      const count = model.activeRequests;
      rows.push(infoRow("wave", "Model is generating", count + (count === 1 ? " request" : " requests"), "blue"));
    }
    if (!rows.length) {
      rows.push(jobs.known ? infoRow("check", "Nothing running", "", "green") : infoRow("wait", "Checking scheduled jobs"));
    }
    if (jobs.next) {
      const at = Date.parse(jobs.next.at);
      const seconds = (at - sampledAtMs) / 1000;
      const when = seconds < 60 ? "now" : seconds < 10800 ? "in " + duration(seconds) : dateLabel(at, sampledAtMs, timezone);
      rows.push(infoRow("clock", jobs.next.name, when));
    }
    for (const job of jobs.lastRunFailed) rows.push(infoRow("warning", job, "last run failed", "orange"));
    if (gateway.ready === false) rows.push(infoRow("warning", "Gateway starting", "", "orange"));
  }
  $("activity").replaceChildren(...rows);
}

function renderContext(context, live) {
  $("context_section").hidden = !context || (!live && !context.live);
  if ($("context_section").hidden) return;
  const { tokens: used, windowTokens: total, percent, phase, compactions } = context;
  text("session", context.session);
  text("context_tokens", Number.isFinite(used) ? tokens(used) : "");
  text("context_window", Number.isFinite(used) ? (total ? "of " + tokens(total) + " tokens" : "tokens") : "Waiting for a model call");
  text("context_percent", Number.isFinite(percent) ? Math.round(percent) + "%" : "");
  text("phase", phase);
  text("compactions", compactions == null ? "" : compactions === 0 ? "Not compacted" :
    compactions === 1 ? "Compacted once" : "Compacted " + compactions + "×");
  meter("context_meter", (percent ?? 0) / 100, percent > 90 ? "--red" : percent > 75 ? "--orange" : "--blue");
}

function detailList(values) {
  const list = [];
  for (const [label, value] of values) {
    if (value != null && value !== "") list.push(element("dt", "", label), element("dd", "", String(value)));
  }
  $("model_details").replaceChildren(...list);
}

function renderModel(sample) {
  const { model: m, memory: mem, name } = sample;
  $("model_section").hidden = false;
  text("runtime", m.reachable ? (m.runtime.startsWith("Splash") ? "Splash · MLX" : m.runtime) : "");
  const short = m.id?.split("/").pop().replace(/(?:[-_.](?:\d+[-_]?bits?|mlx|gguf|q\d\w*|iq\d\w*|int\d+|fp16|bf16|f16|awq|gptq|mxfp4))+$/i, "");
  text("model_name", m.displayName ?? (short || m.id || (m.reachable ? "Unknown model" : "Model unavailable")));
  text("model_id", m.reachable ? (m.id !== short ? (m.id ?? "") : "") : m.runtime);
  const effort = m.effort && (["none", "off"].includes(m.effort) ? "Thinking off" :
    (m.effort === "xhigh" ? "XHigh" : m.effort[0].toUpperCase() + m.effort.slice(1)) + " effort");
  const weights = m.weights?.bits;
  $("model_badges").replaceChildren(
    ...[m.weights?.badge ?? (weights && (weights >= 16 ? "BF16" : Math.floor(weights) + "-bit")), effort]
      .filter(Boolean).map((label) => element("span", "badge", label)),
  );
  $("tiles").hidden = !m.reachable;
  const speed = m.liveTokensPerSecond ?? m.decodeTokensPerSecond;
  text("speed", Number.isFinite(speed) ? Math.round(speed) + " tok/s" : "—");
  text("speed_note", m.liveTokensPerSecond != null ? "live" : m.decodeTokensPerSecond != null ? "typical" : "");
  $("speed_note").classList.toggle("live", m.liveTokensPerSecond != null);
  text("first_token", m.timeToFirstTokenSeconds == null ? "—" : m.timeToFirstTokenSeconds.toFixed(1) + " s");
  text("first_token_note", m.timeToFirstTokenSeconds == null ? "" : "typical");
  text("cache", memory(m.kvCache?.reservedBytes));
  text("cache_note", m.kvCache?.bits ? Math.min(16, Math.floor(m.kvCache.bits)) + "-bit" : "");

  $("memory_section").hidden = !(mem?.totalBytes > 0);
  if (mem?.totalBytes > 0) {
    const assistant = Math.min(mem.usedBytes, mem.assistantBytes ?? 0);
    const other = Math.max(0, mem.usedBytes - assistant);
    const pressure = m.memoryPressure;
    text("memory_label", pressure && !["normal", "nominal"].includes(pressure.toLowerCase()) ? "Memory · " + pressure : "Memory");
    text("memory_free", memory(mem.freeBytes) + " free of " + memory(mem.totalBytes));
    meter("memory_meter", assistant / mem.totalBytes);
    $("memory_meter").lastElementChild.style.width = (100 * other / mem.totalBytes) + "%";
    const legend = [
      assistant > 0 && element("span", "dot assistant", name + " " + memory(assistant)),
      element("span", "dot other", "Other " + memory(other)),
      element("span", "dot free", "Free " + memory(mem.freeBytes)),
    ];
    $("memory_legend").replaceChildren(...legend.filter(Boolean));
  }

  const quality = m.estimatedQualityPercent;
  $("quality_section").hidden = !m.reachable || !Number.isFinite(quality);
  if (!$("quality_section").hidden) {
    text("quality", "≈" + quality.toFixed(1) + "%");
    meter("quality_meter", quality / 100, quality >= 97 ? "--green" : quality >= 85 ? "--orange" : "--red");
  }
  $("details").hidden = !m.reachable;
  detailList([
    ["Runtime", m.runtime],
    ["In use", m.requestedAs],
    ["Served as", m.servedAs?.join(", ")],
    ["Weights", m.weights?.label],
    ["On disk", m.weights?.bytesOnDisk == null ? null : memory(m.weights.bytesOnDisk)],
    ["KV format", m.kvCache?.label],
    ["KV memory", m.kvCache?.usedBytes == null ? null : memory(m.kvCache.usedBytes) + " used"],
    ["Max context", m.contextTokens ? number.format(m.contextTokens) + " tokens" : null],
    ["GPU memory", m.memoryBytes == null ? null : memory(m.memoryBytes)],
    ["Peak memory", m.peakMemoryBytes == null ? null : memory(m.peakMemoryBytes)],
    ["Typical speed", m.decodeTokensPerSecond == null ? null : Math.round(m.decodeTokensPerSecond) + " tok/s"],
    ["Prompt cache", m.promptCacheHitRate == null ? null : Math.round(m.promptCacheHitRate * 100) + "% hits"],
    ["Speculative", m.speculativeDecoding == null ? null : m.speculativeDecoding ? "On" : "Off"],
  ]);
}

function recurrence(job, timezone) {
  if (job.kind === "at") return "One time";
  if (job.kind === "every" && job.everyMs > 0) return "Every " + duration(job.everyMs / 1000);
  if (job.kind !== "cron" || !job.expression) return "Scheduled";
  const fields = job.expression.trim().split(/\s+/);
  const [minute, hours, day, month, weekday] = fields;
  const localZone = job.timezone && job.timezone !== timezone ? " · " + job.timezone : "";
  const numericHour = /^(?:[01]?\d|2[0-3])(?:,(?:[01]?\d|2[0-3]))*$/;
  let label = "Cron · " + job.expression;
  if (fields.length === 5 && /^\d{1,2}$/.test(minute) && day === "*" && month === "*") {
    const min = minute.padStart(2, "0");
    const interval = hours.match(/^\*\/(\d+)$/);
    if (hours === "*" && weekday === "*") label = "Hourly · minute " + min;
    if (interval && weekday === "*") label = "Every " + interval[1] + " hours · minute " + min;
    if (numericHour.test(hours) && (weekday === "*" || /^[0-7](?:,[0-7])*$/.test(weekday))) {
      const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
      const repeat = weekday === "*" ? "Daily" : weekday.split(",").map((d) => days[Number(d) % 7]).join(", ");
      const times = hours.split(",").map((h) => h.padStart(2, "0") + ":" + min).join(", ");
      label = repeat + " · " + times;
    }
  }
  return label + localZone;
}

let scheduleSignature = "";
function renderSchedule(sample) {
  const { schedule, sampledAtMs, timezone, gateway } = sample;
  $("schedule_section").hidden = false;
  const day = new Intl.DateTimeFormat("en-GB", { timeZone: timezone }).format(sampledAtMs);
  const signature = JSON.stringify([schedule, day, timezone, gateway.live]);
  if (signature === scheduleSignature) return;
  scheduleSignature = signature;
  const active = schedule?.filter((job) => job.enabled).length;
  text("schedule_count", schedule && gateway.live ? active + " active" : schedule ? "Last saved" : "");
  if (!schedule?.length) {
    $("schedule").replaceChildren(element("p", "muted", schedule ? "No scheduled tasks" : "Schedule unavailable"));
    return;
  }
  const ordered = schedule.slice().sort((a, b) =>
    Number(b.enabled) - Number(a.enabled) || (a.nextRunAtMs ?? Infinity) - (b.nextRunAtMs ?? Infinity) ||
    a.name.localeCompare(b.name),
  );
  $("schedule").replaceChildren(...ordered.map((job) => {
    const row = element("div", "schedule_row");
    const title = element("div", "");
    title.append(element("span", "job_name", job.name), element("span", "recurrence", recurrence(job, timezone)));
    const running = gateway.live && Boolean(job.runningAtMs);
    const next = job.nextRunAtMs ? dateLabel(job.nextRunAtMs, sampledAtMs, timezone) : "—";
    row.append(title, element("span", "tail" + (running ? " blue" : ""), running ? "Running" : job.enabled ? next : "Paused"));
    return row;
  }));
}

let lastLearningAt = 0;
function renderLearning(data) {
  if (!data || !Number.isFinite(data.totalRuns)) return;
  $("learning_section").hidden = false;
  text("learning_window", data.projectsTracked ? data.projectsTracked + " projects" : "24h");
  text("learning_runs", data.totalRuns + " runs · " + data.frictionRuns + " friction · " + data.failedRuns + " failed");
  text("learning_clean", data.cleanPercent + "% clean");
  meter("learning_meter", data.cleanPercent / 100, data.cleanPercent >= 80 ? "--green" : data.cleanPercent >= 50 ? "--blue" : "--orange");
  const rows = [];
  if (Number.isFinite(data.evalPassed) && Number.isFinite(data.evalTotal)) {
    const ok = data.evalPassed === data.evalTotal;
    rows.push(infoRow(ok ? "check" : "warning", "RSI benchmark", data.evalPassed + "/" + data.evalTotal + " offline tests", ok ? "green" : "orange"));
  }
  if (data.lastCleanupDate) {
    rows.push(infoRow("check", "Auto-cleanup", data.lastCleanupCount + " quarantined · " + data.lastCleanupDate, "green"));
  }
  $("learning_rows").replaceChildren(...rows);
}

async function refreshLearning() {
  const now = performance.now();
  if (now - lastLearningAt < 15000) return;
  lastLearningAt = now;
  try {
    const r = await fetch("/api/learning", { headers, cache: "no-store" });
    if (r.status === 200) renderLearning(await r.json());
  } catch {
    // non-fatal
  }
}

let lastSample = null;
function render(sample) {
  const { gateway, name } = sample;
  lastSample = sample;
  text("name", name);
  const subtitle = gateway.live ? [
    ["OpenClaw", gateway.version].filter(Boolean).join(" "),
    gateway.uptimeSeconds == null ? "" : "up " + duration(gateway.uptimeSeconds),
    gateway.ready === false ? "Starting" : "",
  ].filter(Boolean).join(" · ") : "OpenClaw gateway offline";
  status(sample.state, subtitle);
  renderActivity(sample);
  renderContext(sample.context, gateway.live);
  renderModel(sample);
  renderSchedule(sample);
  refreshLearning();
  text("freshness", "Live");
}

function waiting(message, label) {
  status("checking", message);
  if (!lastSample) $("activity").replaceChildren(infoRow("wait", label));
  if ($("speed_note").classList.contains("live")) {
    text("speed_note", "last seen");
    $("speed_note").classList.remove("live");
  }
  text("freshness", lastSample ? "Last seen · " + dateLabel(lastSample.sampledAtMs, Date.now(), lastSample.timezone) : "");
}

let pending = null;
let timer = null;
async function refresh() {
  if (document.hidden || pending) return;
  const start = performance.now();
  pending = new AbortController();
  const timeout = setTimeout(() => pending?.abort(), 2400);
  let retry = true;
  try {
    const response = await fetch("/api/status", { headers, cache: "no-store", signal: pending.signal });
    if (response.status === 401) {
      waiting("Private viewer link required", "Open your Jarvis Switch link");
      retry = false;
    } else if (response.status === 202) {
      waiting("Connecting to the Mac…", "Checking…");
    } else if (response.ok) {
      render(await response.json());
    } else {
      waiting("Connection interrupted", "Reconnecting…");
    }
  } catch {
    if (!document.hidden) waiting("Waiting for the Mac…", "Reconnecting…");
  } finally {
    clearTimeout(timeout);
    pending = null;
    if (retry && !document.hidden) timer = setTimeout(refresh, Math.max(0, 1000 - (performance.now() - start)));
  }
}

document.addEventListener("visibilitychange", () => {
  clearTimeout(timer);
  if (document.hidden) pending?.abort();
  else refresh();
});
refresh();
