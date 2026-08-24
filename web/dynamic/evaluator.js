/**
 * evaluator.js — browser-half closure evaluation (docs/dynamic-cordis-spec.md
 * §8, §9 `web/dynamic/evaluator.ts` sketch).
 *
 * Vanilla twin of `_ref/deepseek-harness/packages/extensions/cordis-client-runner/src/client/evaluator.ts`:
 * the package source runs as the body of an async function whose parameters
 * ARE the symbol surface. Shadowing parameters (setTimeout/fetch/require/…)
 * turn the ambient browser globals into teaching redirects without touching
 * the page. The host syntax-prechecked the source at define time (spec §5);
 * SyntaxError handling here is the engine-divergence fallback.
 */
(function () {
  'use strict';

  var ZhDynamic = (window.ZhDynamic = window.ZhDynamic || {});
  var evaluator = (ZhDynamic.evaluator = {});

  var TIMER_REDIRECT
    = 'browser timer globals are unavailable in dynamic packages. Declare inject: [\'timer\'] on the returned plugin, '
      + 'and use ctx.timeout / ctx.interval so the runtime can clean timers up on unload. In React, create timers '
      + 'from an event handler or React.useEffect and return callback-form disposers from the effect cleanup.';
  var FETCH_REDIRECT
    = 'network belongs to the HOST half: register a handler there with harness.handle(method, fn) and call it here '
      + 'via host.call(method, args).';
  var REQUIRE_REDIRECT
    = 'modules cannot be imported here. React arrives as the `React` closure symbol; everything else goes through '
      + 'ctx services or host.call.';

  /**
   * Where each withheld browser global sends the author instead. One home for
   * two consumers: the closure traps below throw these, and a render crash
   * whose message names one of them gets the same redirect appended — a
   * package that reached the global some other way (`window.setInterval`)
   * crashes with the engine's own bare text, and the author needs the
   * redirect either way.
   */
  var DYNAMIC_CLIENT_REDIRECTS = {
    setTimeout: TIMER_REDIRECT,
    setInterval: TIMER_REDIRECT,
    clearTimeout: TIMER_REDIRECT,
    clearInterval: TIMER_REDIRECT,
    fetch: FETCH_REDIRECT,
    require: REQUIRE_REDIRECT,
  };
  evaluator.DYNAMIC_CLIENT_REDIRECTS = DYNAMIC_CLIENT_REDIRECTS;

  /** Callable teaching traps shadowing the ambient globals the closure must not reach. */
  function closureTraps() {
    var traps = {};
    Object.keys(DYNAMIC_CLIENT_REDIRECTS).forEach(function (name) {
      var redirect = DYNAMIC_CLIENT_REDIRECTS[name];
      traps[name] = function () {
        throw new Error(name + ' is not available in a dynamic client half — ' + redirect);
      };
    });
    return traps;
  }

  /** The `harness` seat exists only host-side; any touch teaches the split. */
  function harnessTrap() {
    return new Proxy({}, {
      get: function (_target, prop) {
        throw new Error(
          'harness.' + String(prop) + ' belongs to the HOST half (`code`): register handlers there with '
          + 'harness.handle(method, fn); the browser half calls them via host.call(method, args).');
      },
    });
  }

  /**
   * Per-package style-tag bookkeeping behind the `styles.insert` symbol.
   * @param {string} pluginId - owning Plugin ID, stamped as `data-dyn` on every tag.
   */
  class DynamicCordisStyles {
    constructor(pluginId) {
      this.pluginId = pluginId;
      this.tags = new Set();
    }

    /** Inject one stylesheet, removed automatically on package unload. Returns the early disposer. */
    insert(css) {
      if (typeof css !== 'string') throw new Error('styles.insert(css) needs a CSS string');
      var tag = document.createElement('style');
      tag.dataset.dyn = this.pluginId;
      tag.textContent = css;
      document.head.append(tag);
      this.tags.add(tag);
      var tags = this.tags;
      return function () {
        tags.delete(tag);
        tag.remove();
      };
    }

    /** Live tag count (load-report contribution summary). */
    get count() { return this.tags.size; }

    /** Remove every tag this package still owns (unload path). */
    dispose() {
      this.tags.forEach(function (tag) { tag.remove(); });
      this.tags.clear();
    }
  }
  evaluator.DynamicCordisStyles = DynamicCordisStyles;

  /** Stringify one console argument for the error mirror. */
  function errorText(arg) {
    if (arg instanceof Error) return arg.message;
    if (typeof arg === 'string') return arg;
    if (arg === undefined) return 'undefined';
    try {
      return JSON.stringify(arg);
    } catch (_e) {
      // Circular or otherwise non-serializable console argument: the mirror
      // carries the message, and nothing else here can fail.
      return '[unserializable console argument]';
    }
  }

  /** Tagged write-through console; error lines additionally copy into the load report. */
  function taggedConsole(pluginId, noteError) {
    var tag = '[cordis:' + pluginId + ']';
    var forward = function (level) {
      return function () {
        var args = Array.prototype.slice.call(arguments);
        /* eslint-disable no-console */
        console[level].apply(console, [tag].concat(args));
        if (level !== 'error') return;
        try {
          noteError(args.map(errorText).join(' ').slice(0, 500));
        } catch (_e) { /* the mirror must never break the caller */ }
      };
    };
    return {
      log: forward('log'),
      info: forward('info'),
      warn: forward('warn'),
      error: forward('error'),
      debug: forward('debug'),
    };
  }
  evaluator.taggedConsole = taggedConsole;

  // ── dual-realm instanceof patch (host sandbox.ts:62 twin) ──────────────────
  //
  // The vanilla page evaluates in its own realm, but a package may hand us
  // values from an iframe or another realm boundary; plain instanceof then
  // answers false for perfectly good Arrays/Promises. Each shadowing
  // constructor binding accepts same-realm instances OR a structural match,
  // while forwarding every static member unchanged.

  function classOf(value) {
    return Object.prototype.toString.call(value).slice(8, -1); // e.g. "Array"
  }

  function realmTwin(Ctor, matches) {
    return new Proxy(Ctor, {
      get: function (target, prop) {
        if (prop === Symbol.hasInstance) {
          return function (instance) {
            try {
              if (matches(instance)) return true;
              return instance instanceof target;
            } catch (_e) {
              return false;
            }
          };
        }
        var value = Reflect.get(target, prop, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });
  }

  function realmTwins() {
    var isObjectLike = function (i) {
      return i !== null && (typeof i === 'object' || typeof i === 'function');
    };
    return [
      ['Object', realmTwin(Object, isObjectLike)],
      ['Array', realmTwin(Array, function (i) { return classOf(i) === 'Array'; })],
      ['Function', realmTwin(Function, function (i) { return typeof i === 'function'; })],
      ['Error', realmTwin(Error, function (i) {
        return (i instanceof Error) || (i && typeof i.name === 'string' && /Error$/.test(i.name));
      })],
      ['Promise', realmTwin(Promise, function (i) { return classOf(i) === 'Promise'; })],
      ['RegExp', realmTwin(RegExp, function (i) { return classOf(i) === 'RegExp'; })],
      ['Date', realmTwin(Date, function (i) { return classOf(i) === 'Date'; })],
      ['Map', realmTwin(Map, function (i) { return classOf(i) === 'Map'; })],
      ['Set', realmTwin(Set, function (i) { return classOf(i) === 'Set'; })],
    ];
  }

  /**
   * Narrow a closure return value to a mountable plugin (host guard mirror).
   * @returns whether the value is mountable: a function, or an object with an `apply(ctx)` method.
   */
  function isDynamicCordisPlugin(value) {
    if (typeof value === 'function') return true;
    return typeof value === 'object' && value !== null && typeof value.apply === 'function';
  }
  evaluator.isDynamicCordisPlugin = isDynamicCordisPlugin;

  /**
   * Evaluate one package's browser half and return the (un-guarded) plugin.
   *
   * @param {string} pluginId - stable Plugin ID (console tag and style ownership).
   * @param {string} clientCode - the browser half's source: an async function body returning a plugin.
   * @param {{invoke: function(string, *=): Promise<*>, noteError: function(string): void, React?: *}} env -
   *   runner wiring for `host.call`, error mirroring, and the React seat.
   * @param {DynamicCordisStyles} styles - the package's style bookkeeping (caller owns disposal).
   * @returns {Promise<*>} the plugin the closure returned (function or `{inject?, apply}` object).
   * @throws teaching errors for syntax failures and non-plugin returns.
   */
  async function evaluateClientHalf(pluginId, clientCode, env, styles) {
    env = env || {};
    var traps = closureTraps();
    var trapNames = Object.keys(traps);
    var twins = realmTwins();
    var parameters = ['React', 'console', 'styles', 'host', 'harness']
      .concat(trapNames, ['process', 'Buffer'], twins.map(function (t) { return t[0]; }));

    var factory;
    try {
      // The wrapper mirrors the host precheck exactly, so line offsets match.
      factory = new Function(parameters.join(','), 'return (async () => {\n' + clientCode + '\n})()');
    } catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
      // Engine-divergence fallback: the host precheck already carried the
      // line/caret teaching; browsers give only the message.
      throw new Error(
        'client half failed to parse in this browser: ' + error.message + '\n'
        + 'The browser half is plain JavaScript (no JSX, no TypeScript); build elements with React.createElement.');
    }

    var host = {
      /**
       * Call a host-half handler of THIS package (harness.handle pairing).
       * A call with nothing to pass omits the argument: it arrives at the
       * handler as `null`, because the wire carries JSON and `undefined` is
       * not JSON.
       */
      call: function (method, args) { return env.invoke(method, args === undefined ? null : args); },
    };

    var closureArgs = [env.React !== undefined ? env.React : window.React, taggedConsole(pluginId, env.noteError),
      styles, host, harnessTrap()]
      .concat(trapNames.map(function (n) { return traps[n]; }),
        [undefined, undefined], // process / Buffer: undefined keeps `typeof` probes safe
        twins.map(function (t) { return t[1]; }));

    var returned = await factory.apply(null, closureArgs);
    if (!isDynamicCordisPlugin(returned)) {
      if (returned === undefined) {
        throw new Error(
          'client half returned `undefined` — did you forget `return`?\n'
          + '  ✓ return (ctx) => { … }\n'
          + "  ✓ return { name: '…', inject: ['slots'], apply(ctx) { … } }");
      }
      throw new Error('client half must `return` a plugin: a function, or an object with an `apply(ctx)` method');
    }
    return returned;
  }

  evaluator.evaluateClientHalf = evaluateClientHalf;
})();
