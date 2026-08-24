/**
 * guard.js — browser-half guard facade (docs/dynamic-cordis-spec.md §3, §8).
 *
 * Browser twin of `_ref/deepseek-harness/packages/extensions/cordis-client-runner/src/client/guard.ts`,
 * reduced to the zero-build vanilla client: a whitelist of lifecycle-safe
 * `ctx` verbs plus optional `ctx.get()` lookup and declared-service property
 * access, with framework internals withheld and Context-valued returns denied.
 * Two seats carry extra machinery: `slots` (auto shadowing priority +
 * contribution ledger) and the timer verbs (require `inject: ['timer']`).
 *
 * This is API discipline, NOT a security boundary: any host-realm helper
 * reachable through an allowed service is page-capable — treat a mounted
 * package like a `bash` grant (spec §8).
 */
(function () {
  'use strict';

  var ZhDynamic = (window.ZhDynamic = window.ZhDynamic || {});
  var guard = (ZhDynamic.guard = {});

  /** Facade verbs beyond declared services (host CTX_VERBS twin). */
  var CTX_VERBS = new Set([
    'effect', 'on', 'once', 'provide',
    'timeout', 'interval', 'setTimeout', 'setInterval', 'throttle', 'debounce',
  ]);
  var TIMER_VERBS = new Set(['timeout', 'interval', 'setTimeout', 'setInterval', 'throttle', 'debounce']);

  /**
   * Brand identifying a cordis Context-shaped value. The vanilla page has no
   * `@deepseek-ai/cordis` import to `instanceof` against, so contexts are
   * detected by this marker instead (same denial, cheaper mechanism).
   */
  var CONTEXT_BRAND = Symbol.for('zh.cordis.context');
  guard.CONTEXT_BRAND = CONTEXT_BRAND;

  /** Framework internals the facade never exposes (spec §3 "withheld"). */
  var WITHHELD_KEYS = new Set(['root', 'fiber', 'registry', 'extend', 'plugin', 'loader', 'scope']);

  function rejectGuard(env, message) {
    var error = new Error(message);
    if (env && typeof env.reportFailure === 'function') env.reportFailure(error);
    throw error;
  }

  /** Whether `value` looks like a cordis Context under the brand check. */
  function isContext(value) {
    return (typeof value === 'object' || typeof value === 'function') && value !== null
      && value[CONTEXT_BRAND] === true;
  }

  /**
   * Reject any service return that is a cordis Context (host guard twin).
   * A package operates through its OWN ctx and declared services — never
   * somebody else's.
   */
  function denyContext(value, service, env) {
    if (isContext(value)) {
      return rejectGuard(env,
        'service "' + service + '" returned a cordis Context, which the dynamic facade does not expose. '
        + 'Operate through your own plugin ctx and the services you declared — never another context.');
    }
    return value;
  }

  /**
   * Forward service methods with the traced service as receiver — `this.ctx`
   * inside prototype methods (e.g. slots.register) must stay the CALLER's
   * service object so effects land on the calling plugin — while denying
   * Context returns on both sync and async results.
   */
  function guardedService(service, name, env) {
    return new Proxy(service, {
      get: function (target, prop) {
        var value = Reflect.get(target, prop, target);
        if (typeof value !== 'function') return denyContext(value, name, env);
        return function () {
          var args = arguments;
          var result = Reflect.apply(value, target, args);
          if (result instanceof Promise) return result.then(function (r) { return denyContext(r, name, env); });
          return denyContext(result, name, env);
        };
      },
    });
  }

  /**
   * The slots seat: every registration gets a page-local shadowing rank
   * (later registrations sort first) and lands in the contribution ledger;
   * the seated component is claimed so a later crash can be attributed back
   * to this package. Everything else forwards through the generic guard.
   */
  function guardedSlots(slots, env) {
    return new Proxy(slots, {
      get: function (target, prop) {
        if (prop !== 'register') return guardedService(target, 'slots', env)[prop];
        return function (rawOptions, component) {
          if (typeof rawOptions !== 'object' || rawOptions === null) {
            return rejectGuard(env, 'slots.register(options, component) needs an options object with a `name`');
          }
          var options = Object.assign({}, rawOptions);
          var slot = options.name;
          if (typeof slot !== 'string' || slot.length === 0) {
            return rejectGuard(env, 'slots.register options need a string `name` (the target slot key)');
          }
          if (options.priority === undefined) {
            options.priority = env.allocatePriority();
          }
          var dispose = target.register(options, component);
          env.ledger.push({ slot: slot, priority: options.priority });
          // After the registry accepted it: a rejected registration seats no
          // entry, so claiming one would index a component no crash can name.
          env.claim(component);
          return dispose;
        };
      },
    });
  }

  /**
   * Collapse a returned plugin's `inject` declaration to service names
   * (array form, or object form whose keys are the declarations).
   */
  function declaredInjects(plugin) {
    var inject = plugin && plugin.inject;
    if (Array.isArray(inject)) return inject.filter(function (n) { return typeof n === 'string'; });
    if (inject && typeof inject === 'object') return Object.keys(inject);
    return [];
  }
  guard.declaredInjects = declaredInjects;

  /**
   * Build the facade one dynamic plugin's `apply` receives (host
   * sandboxContext twin, browser seats).
   *
   * @param {*} ctx - the plugin's activation context, a plain object with:
   *   getService(name) -> service | undefined   (optional lookup source)
   *   declared       -> Set<string>             (this plugin's inject names)
   *   callVerb(verb, args) -> applies the lifecycle verb on the backing fiber
   * @param {*} env - {pkg, ledger, claim, allocatePriority, reportFailure}.
   * @returns the whitelisting proxy standing in for ctx.
   */
  function dynamicCordisContext(ctx, env) {
    var declared = ctx.declared instanceof Set ? ctx.declared : new Set(declaredInjects({ inject: ctx.declared }));

    var denyRead = function (prop) {
      if (ctx.getService(prop) !== undefined) {
        return rejectGuard(env,
          'service "' + prop + '" is not declared by your plugin. Declare it on the plugin you return: '
          + "{ inject: ['" + prop + "', …], apply(ctx) { … } } — a plain `function` has no declaration site, "
          + 'so use the object form. The runtime then parks the package if the provider unloads.');
      }
      return rejectGuard(env,
        'dynamic ctx does not expose "' + prop + '". Available: ctx.on / ctx.provide / timer helpers after '
        + "injecting timer, and any service your returned plugin declared in inject (slots is the usual UI "
        + 'seat). Framework internals are withheld by design.');
    };

    var readService = function (name, requireDeclaration) {
      if (requireDeclaration && WITHHELD_KEYS.has(name)) return denyRead(name);
      if (requireDeclaration && !declared.has(name)) return denyRead(name);
      var service = denyContext(ctx.getService(name), name, env);
      if (service === null || (typeof service !== 'object' && typeof service !== 'function')) return service;
      if (name === 'slots') return guardedSlots(service, env);
      return guardedService(service, name, env);
    };

    return new Proxy({}, {
      get: function (_target, prop) {
        if (prop === 'get') {
          return function (name) { return readService(name, false); };
        }
        if (typeof prop !== 'string') return undefined;
        // Lazy verb forwarder (host twin): resolve the verb only when called.
        if (CTX_VERBS.has(prop)) {
          return function () {
            var args = Array.prototype.slice.call(arguments);
            if (TIMER_VERBS.has(prop) && !declared.has('timer')) {
              return rejectGuard(env,
                'browser timer globals are unavailable in dynamic packages. Declare inject: [\'timer\'] on the '
                + 'returned plugin, then use ctx.' + prop + ' so the runtime can clean the timer up on unload.');
            }
            return ctx.callVerb(prop, args);
          };
        }
        return readService(prop, true);
      },
      set: function (_target, prop) {
        return rejectGuard(env, 'dynamic ctx is read-only; cannot assign "' + String(prop) + '"');
      },
      has: function (_target, prop) {
        return prop === 'get'
          || (typeof prop === 'string'
            && ((CTX_VERBS.has(prop) && (!TIMER_VERBS.has(prop) || declared.has('timer'))) || declared.has(prop)));
      },
    });
  }

  guard.CTX_VERBS = CTX_VERBS;
  guard.TIMER_VERBS = TIMER_VERBS;
  guard.denyContext = denyContext;
  guard.guardedService = guardedService;
  guard.guardedSlots = guardedSlots;
  guard.dynamicCordisContext = dynamicCordisContext;
})();
