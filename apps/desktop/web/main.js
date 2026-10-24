(() => {
  "use strict";

  const base = "http://127.0.0.1:4174";
  const connection = document.querySelector("#connection");
  const offline = document.querySelector("#offline");
  const dashboard = document.querySelector("#dashboard");
  const refresh = document.querySelector("#refresh");
  const autostart = document.querySelector("#autostart");
  const tauri = window.__TAURI__;
  let lastStates = null;
  let retryTimer = null;

  const invoke = (command, args = {}) => tauri?.core?.invoke(command, args);
  const setConnection = (ok, message) => {
    connection.textContent = message;
    connection.className = `connection ${ok ? "" : "offline"}`;
    offline.hidden = ok;
  };

  function entityStates(snapshot) {
    const states = new Map();
    for (const run of snapshot.runs || []) states.set(`run:${run.id || run.title}`, run.status);
    for (const run of snapshot.loopRuns || []) states.set(`loop-run:${run.id || run.title}`, run.status);
    for (const loop of snapshot.gauntlets || []) {
      states.set(`loop:${loop.id || loop.title}`, loop.live?.status || loop.status);
    }
    return states;
  }

  async function notifyTransitions(next) {
    if (!lastStates) {
      lastStates = next;
      return;
    }
    const notable = new Set(["complete", "completed", "paused", "blocked", "failed", "capped"]);
    for (const [id, status] of next) {
      const previous = lastStates.get(id);
      if (previous && previous !== status && notable.has(String(status).toLowerCase())) {
        await invoke("notify_transition", {
          title: "Chief activity changed",
          body: `${id.replace(/^\w+:/, "")} moved from ${previous} to ${status}`,
        }).catch(() => {});
      }
    }
    lastStates = next;
  }

  async function load() {
    try {
      const [healthResponse, snapshotResponse] = await Promise.all([
        fetch(`${base}/health`, { cache: "no-store" }),
        fetch(`${base}/api/v1/snapshot`, { cache: "no-store" }),
      ]);
      if (!healthResponse.ok || !snapshotResponse.ok) throw new Error("observer unavailable");
      const health = await healthResponse.json();
      const snapshot = await snapshotResponse.json();
      setConnection(true, `chiefd ${health.version} · ${snapshot.projects?.length || 0} projects`);
      await notifyTransitions(entityStates(snapshot));
      await tauri?.event?.emit("observer-summary", {
        projects: snapshot.projects?.length || 0,
        active: [...(snapshot.runs || []), ...(snapshot.loopRuns || [])].filter((run) => ["running", "active", "in-progress"].includes(run.status)).length,
      });
    } catch (_error) {
      setConnection(false, "chiefd offline");
    }
  }

  function reconnectEvents() {
    const events = new EventSource(`${base}/api/v1/events`);
    events.addEventListener("snapshot.updated", async () => {
      await load();
      dashboard.contentWindow?.location.reload();
    });
    events.onerror = () => {
      events.close();
      clearTimeout(retryTimer);
      retryTimer = setTimeout(reconnectEvents, 3000);
    };
  }

  refresh.addEventListener("click", async () => {
    setConnection(true, "Refreshing sources…");
    await fetch(`${base}/api/v1/refresh`, { method: "POST" }).catch(() => null);
    await load();
    dashboard.contentWindow?.location.reload();
  });
  autostart.addEventListener("change", async () => {
    try {
      await invoke("set_autostart", { enabled: autostart.checked });
    } catch (_error) {
      autostart.checked = !autostart.checked;
    }
  });
  tauri?.event?.listen("observer-refresh", () => refresh.click());

  invoke("autostart_enabled").then((enabled) => { autostart.checked = Boolean(enabled); }).catch(() => {});
  load();
  reconnectEvents();
})();
