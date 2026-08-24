/**
 * boot.js — dynamic Cordis browser-half orchestrator (docs/dynamic-cordis-spec.md
 * §4 transport mapping, §7 WebSocket decision, §9 `runtime.ts`/`orchestrator.ts`/
 * `boot.ts` sketches).
 *
 * Vanilla twin of the DSH cordis-client-runner client, reduced for the
 * zero-build zharness page:
 *
 *   DOWNLINK — one WebSocket to GET /api/events.mux (reconnect + backoff),
 *   routing exactly the four allowlisted ServerRequest frames:
 *     cordis/request-run            → approval affordance
 *     cordis/request-run-resolved   → drop that affordance
 *     dynamicCordisRunner/package   → fetch code, evaluate, guard, mount
 *     dynamicCordisRunner/retract   → clean unload
 *
 *   UPLINK — approval answers ride POST /api/respond as the cordis leg of the
 *   multiplexed ClientResponse shape (src/dynamic/wire.zig):
 *     {type:'client-response', rpcId:<echoed frame id>,
 *      result:{ok:true, value:{requestId, decision}}}
 *
 *   Unary helpers use the shared envelope: POST /api/<method> with a
 *   `client-request` body, `result.ok/value` response (docs/dsh-reuse-spec.md §4):
 *     dynamic.getClientCode  — the ONLY path client source reaches this page (spec §4)
 *     dynamic.invoke         — host.call routing into the package's host half (spec §7)
 *
 * Mounting rides the existing module loader when one is booted
 * (`window.__ModuleLoader__.load({id, factory})`, invalidated before every
 * re-registration); activation then runs the guarded `apply` against a local
 * mini-fiber so unload disposes effects/timers/listeners deterministically.
 * Loads converge by (pluginId, pluginRunId): re-delivering the running
 * package is a no-op, a newer run replaces it, retract unloads exactly one
 * activation. Operations are serialized per plugin id.
 */
(function () {
  'use strict';

  var ZhDynamic = (window.ZhDynamic = window.ZhDynamic || {});
  var guard = ZhDynamic.guard;
  var evaluator = ZhDynamic.evaluator;

  /** Frame payload types this page listens for (spec §4 api-remotes allowlist). */
  var FRAME_TYPES = new Set([
    'cordis/request-run',
    'cordis/request-run-resolved',
    'dynamicCordisRunner/package',
    'dynamicCordisRunner/retract',
  ]);

  /** Decisions a page may answer with (resolvable RequestRunOutcome subset). */
  var PAGE_DECISIONS = new Set(['approved', 'rejected']);

  function moduleIdOf(pluginId) {
    return 'dyn/' + pluginId;
  }

  // ── unary transport ─────────────────────────────────────────────────────────

  var rpcCounter = 0;

  /**
   * One unary call over the shared envelope. Always HTTP 200 on the wire;
   * business errors surface as rejections here.
   */
  async function postUnary(method, payload) {
    var rpcId = 'dyn-web-' + (++rpcCounter);
    var res = await fetch('/api/' + method, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ type: 'client-request', rpcId: rpcId, method: method, payload: payload }),
    });
    var body = null;
    try {
      body = await res.json();
    } catch (_e) { /* fall through to malformed */ }
    var result = body && body.result;
    if (!result) throw new Error(method + ': malformed server response');
    if (!result.ok) {
      var err = new Error((result.error && result.error.message) || (method + ' failed'));
      err.code = result.error && result.error.code;
      throw err;
    }
    return result.value;
  }

  /** Fire-and-forget unary (diagnostics must never become a second failure). */
  function postForget(method, payload) {
    postUnary(method, payload).catch(function (error) {
      console.warn('[dynamic] ' + method + ' failed:', error.message);
    });
  }

  // ── mux downlink ────────────────────────────────────────────────────────────

  /** Connect to /api/events.mux with reconnect + exponential backoff (cap 15s). */
  function connectMux(onFrame) {
    var ws = null;
    var closed = false;
    var attempt = 0;

    function open() {
      var proto = location.protocol === 'https:' ? 'wss://' : 'ws://';
      ws = new WebSocket(proto + location.host + '/api/events.mux');
      ws.onopen = function () { attempt = 0; };
      ws.onmessage = function (ev) {
        var frame;
        try {
          frame = JSON.parse(ev.data);
        } catch (_e) {
          return; // not JSON: never ours
        }
        if (!frame || frame.type !== 'server-request') return;
        var payloadType = frame.payload && frame.payload.type;
        var kind = FRAME_TYPES.has(payloadType) ? payloadType : (FRAME_TYPES.has(frame.method) ? frame.method : null);
        if (kind === null || !frame.payload) return;
        try {
          onFrame(kind, frame);
        } catch (error) {
          console.error('[dynamic] frame handler crashed:', error);
        }
      };
      ws.onclose = function () {
        if (closed) return;
        setTimeout(open, Math.min(15000, 1000 * Math.pow(2, attempt++)));
      };
      ws.onerror = function () {
        try { ws.close(); } catch (_e) { /* already closing */ }
      };
    }

    open();
    return function () {
      closed = true;
      try { ws.close(); } catch (_e) { /* idempotent */ }
    };
  }

  // ── module loader sink (client-modules contract C6 twin) ───────────────────

  function moduleSink() {
    return window.__ModuleLoader__ && typeof window.__ModuleLoader__.load === 'function'
      ? window.__ModuleLoader__
      : null;
  }

  function invalidateModule(moduleId) {
    var sink = window.__ModuleLoader__;
    if (sink && typeof sink.invalidate === 'function') sink.invalidate(moduleId);
  }

  // ── local mini-fiber: lifecycle verbs + deterministic unload ───────────────

  /**
   * A minimal fiber backing the guard facade. Provides the CTX_VERBS over
   * tracked disposables so teardown runs them LIFO; services resolve from the
   * page-level service store (`ZhDynamic.services`), which future phases (or
   * an embedding shell) populate — a declared service that is absent PARKS
   * the package instead of failing it.
   *
   * @param {string[]} declaredNames - the plugin's collapsed inject declarations;
   *   the guard facade gates service property access on exactly these.
   */
  function makeFiber(declaredNames) {
    var disposers = [];
    var provides = {};
    var bus = {}; // eventName -> Set<handler>

    function track(dispose) {
      disposers.push(typeof dispose === 'function' ? dispose : function () {});
    }

    function emit(event, payload) {
      var handlers = bus[event];
      if (!handlers) return;
      Array.from(handlers).forEach(function (fn) {
        try {
          fn(payload);
        } catch (error) {
          console.error('[dynamic] event handler threw:', error);
        }
      });
    }

    var verbs = {
      effect: function (fn /* , name */) {
        track(fn());
      },
      on: function (event, handler) {
        (bus[event] = bus[event] || new Set()).add(handler);
        track(function () { bus[event].delete(handler); });
        return function () { bus[event].delete(handler); };
      },
      once: function (event, handler) {
        var wrapped = function (payload) {
          verbs.off(event, wrapped);
          handler(payload);
        };
        return verbs.on(event, wrapped);
      },
      off: function (event, handler) {
        if (bus[event]) bus[event].delete(handler);
      },
      provide: function (key, value) {
        provides[key] = value;
        emit('provide:' + key, value);
      },
      timeout: function (fn, ms) {
        var t = setTimeout(fn, ms);
        track(function () { clearTimeout(t); });
        return t;
      },
      interval: function (fn, ms) {
        var t = setInterval(fn, ms);
        track(function () { clearInterval(t); });
        return t;
      },
      throttle: function (fn, ms) {
        var last = 0;
        return function () {
          var now = Date.now();
          if (now - last >= ms) {
            last = now;
            fn.apply(null, arguments);
          }
        };
      },
      debounce: function (fn, ms) {
        var t = null;
        track(function () { clearTimeout(t); });
        return function () {
          var args = arguments;
          clearTimeout(t);
          t = setTimeout(function () { fn.apply(null, args); }, ms);
        };
      },
    };
    verbs.setTimeout = verbs.timeout;
    verbs.setInterval = verbs.interval;

    return {
      getService: function (name) { return ZhDynamic.services.get(name); },
      declared: new Set(declaredNames),
      callVerb: function (verb, args) {
        if (typeof verbs[verb] !== 'function') throw new Error('unknown ctx verb "' + verb + '"');
        return verbs[verb].apply(null, args);
      },
      emit: emit,
      provides: provides,
      dispose: function () {
        while (disposers.length > 0) {
          var dispose = disposers.pop();
          try {
            dispose();
          } catch (_e) { /* teardown is best-effort, one bad disposer stops nothing */ }
        }
      },
    };
  }

  // ── the runner (runtime.ts twin, reduced) ───────────────────────────────────

  function createRunner() {
    var live = new Map();       // pluginId -> LivePackage
    var queues = new Map();     // pluginId -> Promise tail
    var failures = new Map();   // pluginId -> last load/activate failure row
    var nextPriority = 0;
    var owners = new WeakMap(); // seated component -> {pluginId, pluginRunId}
    var changeListeners = new Set();

    function notify() {
      changeListeners.forEach(function (fn) {
        try {
          fn();
        } catch (_e) { /* a broken subscriber must not wedge the runner */ }
      });
    }

    function enqueue(id, op) {
      var previous = queues.get(id) || Promise.resolve();
      var next = previous.then(op);
      // The queue tail must survive failure, or one rejection wedges every
      // later operation on the same package.
      queues.set(id, next.then(function () {}, function () {}));
      return next;
    }

    function errorDetails(error) {
      if (!(error instanceof Error)) return { message: String(error) };
      var details = { message: error.message };
      if (typeof error.stack === 'string') details.stack = error.stack;
      return details;
    }

    /** Wrap the evaluated plugin so `apply` sees the guard facade. */
    function guardedSurface(pkg, plugin, ledger) {
      var env = {
        pkg: pkg,
        ledger: ledger,
        claim: function (component) {
          if ((typeof component === 'object' && component !== null) || typeof component === 'function') {
            owners.set(component, { pluginId: pkg.pluginId, pluginRunId: pkg.pluginRunId });
          }
        },
        allocatePriority: function () { return --nextPriority; },
        reportFailure: function (error) {
          // Guard rejections are teaching diagnostics for the authoring session.
          console.error('[dynamic] guard rejected "' + pkg.pluginId + '":', error.message);
        },
      };
      if (typeof plugin === 'function') {
        return {
          inject: [],
          apply: function (ctx) { return plugin(guard.dynamicCordisContext(ctx, env)); },
        };
      }
      return {
        name: moduleIdOf(pkg.pluginId),
        inject: plugin.inject,
        apply: function (ctx, config) { return plugin.apply(guard.dynamicCordisContext(ctx, env), config); },
      };
    }

    async function mount(half) {
      var styles = new evaluator.DynamicCordisStyles(half.pluginId);
      var ledger = [];
      var pkg = {
        pluginId: half.pluginId,
        packageId: half.packageId,
        pluginRunId: half.pluginRunId,
        name: half.name,
      };

      var plugin;
      try {
        plugin = await evaluator.evaluateClientHalf(half.pluginId, half.code, {
          invoke: function (method, args) {
            return postUnary('dynamic.invoke', {
              pluginId: half.pluginId,
              pluginRunId: half.pluginRunId,
              method: method,
              args: args,
            }).then(function (value) {
              // Spec §7: the invoke value is {ok,value} | {code,message}.
              if (value && value.ok === false) {
                var err = new Error(value.message || 'host.call failed');
                err.code = value.code;
                throw err;
              }
              return value ? value.value : null;
            });
          },
          noteError: function (message) {
            // A loaded package's own console.error: page-local diagnostic.
            console.error('[dynamic] ' + half.pluginId + ' logged an error:', message);
          },
          React: window.React,
        }, styles);
      } catch (error) {
        styles.dispose();
        failures.set(half.pluginId, Object.assign({ cause: 'evaluate' }, errorDetails(error)));
        notify();
        throw error;
      }

      var surface = guardedSurface(pkg, plugin, ledger);
      surface.name = moduleIdOf(half.pluginId);

      // Invalidate-then-register keeps re-loading legal: the module table
      // throws loudly on a duplicate factory registration.
      var moduleId = moduleIdOf(half.pluginId);
      invalidateModule(moduleId);
      var sink = moduleSink();
      if (sink) {
        sink.load({ id: moduleId, factory: function () { return surface; } });
      } else {
        console.warn('[dynamic] window.__ModuleLoader__ missing — activating without a module-table seat');
      }

      var fiber = makeFiber(guard.declaredInjects(surface));
      // Declared but absent service = parked (a success that waits, spec §5 status model).
      var waitingFor = Array.from(fiber.declared).filter(function (name) {
        return fiber.getService(name) === undefined;
      });

      var record = {
        pkg: pkg,
        moduleId: moduleId,
        styles: styles,
        ledger: ledger,
        fiber: fiber,
        parked: waitingFor.length > 0,
        waitingFor: waitingFor,
      };

      if (!record.parked) {
        try {
          await surface.apply(fiber);
        } catch (error) {
          fiber.dispose();
          invalidateModule(moduleId);
          styles.dispose();
          failures.set(half.pluginId, Object.assign({ cause: 'activate' }, errorDetails(error)));
          notify();
          throw error;
        }
      }

      live.set(half.pluginId, record);
      failures.delete(half.pluginId);
      notify();
      return record;
    }

    async function teardown(id) {
      var current = live.get(id);
      if (current === undefined) return;
      live.delete(id);
      failures.delete(id);
      // Fiber disposal cascades facade effects/timers/listeners; factory
      // invalidation makes a later re-load legal; styles come off the DOM.
      current.fiber.dispose();
      invalidateModule(current.moduleId);
      current.styles.dispose();
      notify();
    }

    return {
      /** Load one browser half; converges by (pluginId, pluginRunId). */
      load: function (half) {
        return enqueue(half.pluginId, async function () {
          var current = live.get(half.pluginId);
          if (current !== undefined) {
            // Already running this activation here: nothing to load (a
            // replayed run must not look unacknowledged — page reload recovery
            // converges by the same rule).
            if (current.pkg.pluginRunId === half.pluginRunId) return current;
            await teardown(half.pluginId);
          }
          return mount(half);
        });
      },

      /** Unload exactly one activation; a newer run survives. */
      retract: function (pluginId, pluginRunId) {
        return enqueue(pluginId, async function () {
          var current = live.get(pluginId);
          if (current === undefined || current.pkg.pluginRunId !== pluginRunId) return;
          await teardown(pluginId);
        });
      },

      isLoaded: function (pluginId) { return live.has(pluginId); },

      /** One row per live package in this page (smoke-test/debug projection). */
      snapshot: function () {
        return Array.from(live.values()).map(function (r) {
          return {
            pluginId: r.pkg.pluginId,
            packageId: r.pkg.packageId,
            pluginRunId: r.pkg.pluginRunId,
            name: r.pkg.name,
            parked: r.parked,
            waitingFor: r.waitingFor.slice(),
            slots: Array.from(new Set(r.ledger.map(function (row) { return row.slot; }))),
            styleCount: r.styles.count,
          };
        });
      },

      failuresSnapshot: function () {
        var out = {};
        failures.forEach(function (v, k) { out[k] = v; });
        return out;
      },

      subscribe: function (fn) {
        changeListeners.add(fn);
        return function () { changeListeners.delete(fn); };
      },
    };
  }

  // ── approval affordance (§4 flow, browser side) ─────────────────────────────

  function createApprovals(answerFn) {
    var pending = new Map(); // requestId -> {frameRpcId, request}

    function render() {
      var root = document.getElementById('zh-dynamic-approvals');
      if (!root) {
        root = document.createElement('div');
        root.id = 'zh-dynamic-approvals';
        root.style.cssText = 'position:fixed;right:16px;bottom:16px;z-index:2147483647;display:flex;'
          + 'flex-direction:column;gap:8px;font:13px/1.4 system-ui,sans-serif;color:inherit;';
        document.body.appendChild(root);
      }
      root.textContent = '';
      pending.forEach(function (entry, requestId) {
        var r = entry.request;
        var card = document.createElement('div');
        card.dataset.requestId = requestId;
        card.style.cssText = 'min-width:280px;max-width:360px;padding:12px;border-radius:8px;'
          + 'background:Canvas;border:1px solid color-mix(in srgb,CanvasText 25%,transparent);box-shadow:0 4px 16px rgba(0,0,0,.25);';

        var title = document.createElement('strong');
        title.textContent = r.name + ' (' + r.mode + ')';
        card.appendChild(title);

        var meta = document.createElement('div');
        meta.textContent = r.pluginId + ' · ' + r.packageId;
        meta.style.cssText = 'opacity:.65;margin-top:2px;';
        card.appendChild(meta);

        if (r.purpose) {
          var purpose = document.createElement('div');
          purpose.textContent = r.purpose;
          purpose.style.cssText = 'margin-top:6px;';
          card.appendChild(purpose);
        }

        var row = document.createElement('div');
        row.style.cssText = 'margin-top:10px;display:flex;gap:8px;';
        [['Approve', 'approved'], ['Decline', 'rejected']].forEach(function (pair) {
          var btn = document.createElement('button');
          btn.type = 'button';
          btn.textContent = pair[0];
          btn.style.cssText = 'flex:1;padding:6px 10px;border-radius:6px;cursor:pointer;';
          btn.addEventListener('click', function () { answerFn(requestId, pair[1]); });
          row.appendChild(btn);
        });
        card.appendChild(row);
        root.appendChild(card);
      });
    }

    return {
      offered: function (frameRpcId, request) {
        // requiresApproval=false frames are informational; no answer expected.
        if (request.requiresApproval === false) return;
        pending.set(request.requestId, { frameRpcId: frameRpcId, request: request });
        render();
      },
      resolved: function (requestId) {
        if (!pending.delete(requestId)) return;
        render();
      },
      size: function () { return pending.size; },
    };
  }

  // ── boot ────────────────────────────────────────────────────────────────────

  /** Page-level service store backing ctx.get / declared injects. */
  ZhDynamic.services = ZhDynamic.services || new Map();

  function boot() {
    if (ZhDynamic.boot && ZhDynamic.boot.started) return ZhDynamic.boot;

    var runner = createRunner();
    var approvals = createApprovals(function (requestId, decision) {
      if (!PAGE_DECISIONS.has(decision)) return;
      approvals.resolved(requestId); // optimistic drop; the resolved broadcast confirms for every page
      answerApproval(requestId, decision);
    });

    function answerApproval(requestId, decision) {
      var entry = pendingGet(requestId);
      var body = {
        type: 'client-response',
        rpcId: entry ? entry.frameRpcId : 'dyn-web-orphans',
        result: { ok: true, value: { requestId: requestId, decision: decision } },
      };
      fetch('/api/respond', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      }).then(function (res) { return res.json().catch(function () { return null; }); })
        .then(function (receipt) {
          // {"accepted":true} | {"accepted":false,"reason":"not-pending"|"bad-decision"}
          if (receipt && receipt.accepted === false) {
            console.warn('[dynamic] approval answer not settled:', receipt.reason || 'unknown');
          }
        })
        .catch(function (error) {
          console.warn('[dynamic] POST /api/respond failed:', error.message);
        });
    }

    // Last-answer-wins bookkeeping so the echoed rpcId matches the frame the
    // user actually answered (fresh "cordis-<n>" ids are opaque; correlation
    // goes through the PAYLOAD's requestId on the host side).
    var pendingFrames = new Map();
    function pendingGet(requestId) { return pendingFrames.get(requestId); }

    function onFrame(kind, frame) {
      var p = frame.payload;
      switch (kind) {
        case 'cordis/request-run':
          pendingFrames.set(p.requestId, { frameRpcId: frame.rpcId, request: p });
          approvals.offered(frame.rpcId, p);
          break;
        case 'cordis/request-run-resolved':
          pendingFrames.delete(p.requestId);
          approvals.resolved(p.requestId);
          break;
        case 'dynamicCordisRunner/package':
          deliverPackage(p).catch(function (error) {
            console.error('[dynamic] loading ' + p.pluginId + ' failed:', error.message);
          });
          break;
        case 'dynamicCordisRunner/retract':
          void runner.retract(p.pluginId, p.pluginRunId);
          break;
        default:
          break; // unreachable: connectMux pre-filters to the allowlist
      }
    }

    /** package announcement → fetch code (the only source path) → evaluate+guard+mount. */
    async function deliverPackage(p) {
      var value;
      try {
        value = await postUnary('dynamic.getClientCode', {
          pluginId: p.pluginId,
          packageId: p.packageId,
          pluginRunId: p.pluginRunId,
        });
      } catch (error) {
        console.error('[dynamic] getClientCode ' + p.pluginId + '/' + p.packageId + ' failed:', error.message);
        return;
      }
      var code = value && typeof value.code === 'string' ? value.code : null;
      if (code === null) {
        console.error('[dynamic] getClientCode returned no code for ' + p.pluginId + '/' + p.packageId);
        return;
      }
      await runner.load({
        pluginId: p.pluginId,
        packageId: p.packageId,
        pluginRunId: p.pluginRunId,
        name: p.name,
        code: code,
      });
    }

    var disconnect = connectMux(onFrame);

    var api = {
      started: true,
      runner: runner,
      approvals: approvals,
      answerApproval: answerApproval,
      disconnect: disconnect,
    };
    ZhDynamic.boot = api;
    console.info('[dynamic] browser half listening on /api/events.mux');
    return api;
  }

  boot();
})();
