// zer0 compatibility file.
//
// This file is not part of the extension that ships alongside it. zer0 writes
// it during install and points `background` at it, so it runs before the
// extension's own code; `manifest.json` records both facts under `zer0_compat`,
// and the extension's own entry point is re-entered at the bottom of this file.
//
// It exists because a member missing from a namespace that exists is fatal
// under MV3, and there is nothing an extension can do about it. Measured across
// 59 store packages: 14 background workers never start, and six of those die on
// a single missing member — React Developer Tools on
// `chrome.scripting.ExecutionWorld.ISOLATED`, two strings.
//
// ## What is allowed in here
//
// 1. **Enums and constants whose value Chrome documents as a literal.** There
//    is nothing to implement and nothing to get wrong, because the enum *is*
//    its value.
// 2. **Event objects that only need to exist.** MV3 requires listeners to be
//    registered synchronously while the worker starts, so a worker that listens
//    for something this engine lacks is dead before it does anything. An
//    `addListener` that registers and never fires never claims the event
//    happened.
// 3. **`chrome.storage.managed`.** zer0 has no enterprise policy mechanism, so
//    managed storage is empty — not "not implemented", empty. Reading it
//    answers that; writing to it rejects, which is what Chrome does too.
//
// 4. **Methods zer0 really carries out**, over its own channel — the fourth
//    tier, added by ADR-0103, and the one to be most careful about. Nothing is
//    here unless this browser really does the thing: `chrome.downloads` is the
//    download subsystem ADR-0027 and ADR-0101 already built, and
//    `chrome.idle.queryState` is a number the system hands over. Every call
//    goes to `crates/zer0-core/src/extension_api.rs`, which decides — including
//    deciding to refuse.
// 5. **`chrome.management.getSelf`**, computed from the extension's own
//    manifest. It needs no permission in Chrome either and asserts nothing this
//    file does not already have in its hands.
//
// ## What is not, and why
//
// **Anything that would have to do something zer0 does not do.**
// `tabs.executeScript`, `runtime.getContexts`, `i18n.detectLanguage`,
// delivering a notification. A method that resolves without doing the thing is
// a silent failure nobody can diagnose, and it is strictly worse than the loud
// one it replaced (ADR-0077). The fourth tier above is the *opposite* of that
// and stays the opposite only while every method in it is backed: adding one
// that answers out of this file rather than out of the browser is how this
// becomes the thing it was written to prevent.
//
// **Capacity numbers.** `MAX_NUMBER_OF_DYNAMIC_RULES` and its neighbours are
// claims about what *this* engine will accept. Chrome's number is not evidence
// about WebKit's, and stating one would be the browser saying something it
// cannot prove (ADR-0018). Identifiers like `DYNAMIC_RULESET_ID` are not
// capacities and are stated.
//
// **Type names.** `chrome.tabs.Tab` and friends are documentation, undefined in
// Chrome too. A survey that reads a package's source finds them; defining them
// would be inventing surface Chrome does not have.
//
// ## The two rules that keep it from becoming a lie
//
// **Nothing is installed over something that exists.** Every write below is
// guarded, so the day WebKit implements one of these the real one wins and this
// file goes quiet on its own, without anybody re-measuring.
//
// **Nothing is invented.** A member this file does not list stays `undefined`.
// That is deliberate and it is the opposite of the obvious design: a stub
// function that throws when called reads as more helpful, and it would defeat
// `if (chrome.notifications.create)` — the extension's own way of finding out
// and taking another path — while asserting a method exists that does not.
// Leaving it undefined keeps that check honest, and a call to it still fails
// loudly, at the call site, instead of at startup.

(function () {
  'use strict';

  // A registration that is remembered and never fired. `hasListener` answers
  // about registration, which is a fact, and not about delivery, which is not.
  function eventObject() {
    var listeners = [];
    return {
      addListener: function (fn) {
        if (typeof fn === 'function' && listeners.indexOf(fn) === -1) listeners.push(fn);
      },
      removeListener: function (fn) {
        var at = listeners.indexOf(fn);
        if (at !== -1) listeners.splice(at, 1);
      },
      hasListener: function (fn) {
        return listeners.indexOf(fn) !== -1;
      },
      hasListeners: function () {
        return listeners.length > 0;
      },
    };
  }

  // Chrome's documented literals, keyed by the path they live at.
  var ENUMS = {
    'runtime.ContextType': {
      TAB: 'TAB',
      POPUP: 'POPUP',
      BACKGROUND: 'BACKGROUND',
      OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT',
      SIDE_PANEL: 'SIDE_PANEL',
      DEVELOPER_TOOLS: 'DEVELOPER_TOOLS',
    },
    'runtime.OnInstalledReason': {
      INSTALL: 'install',
      UPDATE: 'update',
      CHROME_UPDATE: 'chrome_update',
      SHARED_MODULE_UPDATE: 'shared_module_update',
    },
    'runtime.OnRestartRequiredReason': {
      APP_UPDATE: 'app_update',
      OS_UPDATE: 'os_update',
      PERIODIC: 'periodic',
    },
    'runtime.PlatformArch': {
      ARM: 'arm',
      ARM64: 'arm64',
      X86_32: 'x86-32',
      X86_64: 'x86-64',
      MIPS: 'mips',
      MIPS64: 'mips64',
    },
    'runtime.PlatformOs': {
      MAC: 'mac',
      WIN: 'win',
      ANDROID: 'android',
      CROS: 'cros',
      LINUX: 'linux',
      OPENBSD: 'openbsd',
      FUCHSIA: 'fuchsia',
    },
    'scripting.ExecutionWorld': {
      ISOLATED: 'ISOLATED',
      MAIN: 'MAIN',
    },
    'declarativeNetRequest.DomainType': {
      FIRST_PARTY: 'firstParty',
      THIRD_PARTY: 'thirdParty',
    },
    'declarativeNetRequest.HeaderOperation': {
      APPEND: 'append',
      SET: 'set',
      REMOVE: 'remove',
    },
    'declarativeNetRequest.ResourceType': {
      MAIN_FRAME: 'main_frame',
      SUB_FRAME: 'sub_frame',
      STYLESHEET: 'stylesheet',
      SCRIPT: 'script',
      IMAGE: 'image',
      FONT: 'font',
      OBJECT: 'object',
      XMLHTTPREQUEST: 'xmlhttprequest',
      PING: 'ping',
      CSP_REPORT: 'csp_report',
      MEDIA: 'media',
      WEBSOCKET: 'websocket',
      WEBTRANSPORT: 'webtransport',
      WEBBUNDLE: 'webbundle',
      OTHER: 'other',
    },
    'declarativeNetRequest.RuleActionType': {
      BLOCK: 'block',
      REDIRECT: 'redirect',
      ALLOW: 'allow',
      UPGRADE_SCHEME: 'upgradeScheme',
      MODIFY_HEADERS: 'modifyHeaders',
      ALLOW_ALL_REQUESTS: 'allowAllRequests',
    },
    'declarativeNetRequest.UnsupportedRegexReason': {
      SYNTAX_ERROR: 'syntaxError',
      MEMORY_LIMIT_EXCEEDED: 'memoryLimitExceeded',
    },
    // The whole `On*Options` family, because they are one shape and an
    // extension reaching for the one we happened to measure would have reached
    // for its neighbour just as easily. DuckDuckGo dies on
    // `OnHeadersReceivedOptions.EXTRA_HEADERS`.
    'webRequest.OnBeforeRequestOptions': {
      BLOCKING: 'blocking',
      REQUEST_BODY: 'requestBody',
      EXTRA_HEADERS: 'extraHeaders',
    },
    'webRequest.OnBeforeSendHeadersOptions': {
      REQUEST_HEADERS: 'requestHeaders',
      BLOCKING: 'blocking',
      EXTRA_HEADERS: 'extraHeaders',
    },
    'webRequest.OnSendHeadersOptions': {
      REQUEST_HEADERS: 'requestHeaders',
      EXTRA_HEADERS: 'extraHeaders',
    },
    'webRequest.OnHeadersReceivedOptions': {
      BLOCKING: 'blocking',
      RESPONSE_HEADERS: 'responseHeaders',
      EXTRA_HEADERS: 'extraHeaders',
    },
    'webRequest.OnAuthRequiredOptions': {
      RESPONSE_HEADERS: 'responseHeaders',
      BLOCKING: 'blocking',
      ASYNC_BLOCKING: 'asyncBlocking',
      EXTRA_HEADERS: 'extraHeaders',
    },
    'webRequest.OnResponseStartedOptions': {
      RESPONSE_HEADERS: 'responseHeaders',
      EXTRA_HEADERS: 'extraHeaders',
    },
    'webRequest.OnBeforeRedirectOptions': {
      RESPONSE_HEADERS: 'responseHeaders',
      EXTRA_HEADERS: 'extraHeaders',
    },
    'webRequest.OnCompletedOptions': {
      RESPONSE_HEADERS: 'responseHeaders',
      EXTRA_HEADERS: 'extraHeaders',
    },
    'webRequest.OnErrorOccurredOptions': {
      EXTRA_HEADERS: 'extraHeaders',
    },
    'webRequest.ResourceType': {
      MAIN_FRAME: 'main_frame',
      SUB_FRAME: 'sub_frame',
      STYLESHEET: 'stylesheet',
      SCRIPT: 'script',
      IMAGE: 'image',
      FONT: 'font',
      OBJECT: 'object',
      XMLHTTPREQUEST: 'xmlhttprequest',
      PING: 'ping',
      CSP_REPORT: 'csp_report',
      MEDIA: 'media',
      WEBSOCKET: 'websocket',
      WEBTRANSPORT: 'webtransport',
      WEBBUNDLE: 'webbundle',
      OTHER: 'other',
    },
  };

  // Identifiers, not capacities. Chrome documents these two as the literal
  // names of the two rulesets every extension has.
  var CONSTANTS = {
    'declarativeNetRequest.DYNAMIC_RULESET_ID': '_dynamic',
    'declarativeNetRequest.SESSION_RULESET_ID': '_session',
  };

  // Event objects. Every one of these was measured absent from a namespace that
  // is present, in a package that registers it while its worker starts.
  var EVENTS = [
    'action.onUserSettingsChanged',
    'declarativeNetRequest.onRuleMatchedDebug',
    'extension.onRequest',
    'extension.onRequestExternal',
    'runtime.onBrowserUpdateAvailable',
    'runtime.onPerformanceWarning',
    'runtime.onRestartRequired',
    'runtime.onSuspend',
    'runtime.onSuspendCanceled',
    'runtime.onUpdateAvailable',
    'runtime.onUserScriptConnect',
    'runtime.onUserScriptMessage',
    'webNavigation.onCreatedNavigationTarget',
    'webNavigation.onHistoryStateUpdated',
    'webNavigation.onReferenceFragmentUpdated',
    'windows.onBoundsChanged',
    // The three that need the namespace below to exist at all.
    'notifications.onButtonClicked',
    'notifications.onClicked',
    'notifications.onClosed',
  ];

  // The namespaces this file creates rather than adds to.
  //
  // `notifications` is the original and the whole reason this list exists:
  // 1Password, Redux DevTools and Violentmonkey each call
  // `notifications.onClicked.addListener` at the top level of their worker,
  // which MV3 makes fatal. What gets created carries the three event objects
  // above and nothing else — `create` stays undefined, so an extension that
  // checks for it takes its own other path, and putting a notification on
  // somebody's screen is a permission decision zer0 has not taken (ADR-0103).
  //
  // `downloads`, `idle` and `management` are here because zer0 answers them
  // itself. WebKit installs none of the three, so on this engine every write
  // below is the first one; the guard in `define` still stands, so the day it
  // does install one, WebKit's wins.
  var CREATABLE = ['notifications', 'downloads', 'idle', 'management'];

  // MARK: - The channel

  // How this file reaches the browser. Measured on macOS 26.6: a `fetch` from a
  // background service worker to a scheme the extension controller's
  // configuration has a handler for arrives at that handler, with the body and
  // with an `Origin` naming which extension asked. It is the only road out of a
  // worker that does not need the `nativeMessaging` permission, which most of
  // these packages never asked for.
  var CALL_URL = 'zer0-extension-api://call/';

  // A refusal from the browser reaches the caller as a rejection, and a
  // callback caller gets it thrown.
  //
  // `chrome.runtime.lastError` is what Chrome would set, and this file has no
  // way to set it — the same wall `storage.managed` hit above, answered the
  // same way. Throwing is the loud answer available here, and it is loud at the
  // call site with the browser's own sentence in it, rather than the "is not a
  // function" a missing member would give.
  function call(method, args) {
    return fetch(CALL_URL + method, {
      method: 'POST',
      body: JSON.stringify(args === undefined ? null : args),
    })
      .then(function (response) {
        return response.json();
      })
      .then(function (answered) {
        if (answered && typeof answered.error === 'string') {
          throw new Error(answered.error);
        }
        if (!answered || !('ok' in answered)) {
          throw new Error('zer0 answered ' + method + ' with something unreadable.');
        }
        return answered.ok;
      });
  }

  // Chrome's two calling conventions over one channel. A trailing function is a
  // callback, anything else is a promise.
  //
  // The callback branch does **not** swallow the failure: there is no
  // `lastError` to put it in, so it becomes an unhandled rejection, which is
  // loud in the console and does not take the worker down. Calling the callback
  // with `undefined` would be this file reporting success.
  function bridged(method) {
    return function () {
      var args = Array.prototype.slice.call(arguments);
      var callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
      var answered = call(method, args[0]);
      if (!callback) return answered;
      answered.then(function (value) {
        callback(value);
      });
      return undefined;
    };
  }

  // Every call, including the two the browser only ever refuses.
  //
  // `pause` and `resume` go down the same road as the rest and come back with
  // the reason zer0 will not do them (`extension_api.rs`). Defining them at all
  // is a departure from "nothing is invented" worth being explicit about: this
  // namespace is zer0's, so `if (chrome.downloads.pause)` no longer tells an
  // extension anything about the engine — it would only tell it about this
  // table. A refusal carrying the browser's reason is more use than a silence
  // carrying none.
  //
  // Nothing else Chrome documents on these namespaces is here.
  // `downloads.setShelfEnabled`, `downloads.acceptDanger`,
  // `idle.setDetectionInterval` and the rest stay undefined, so an extension
  // checking for one still finds out honestly, and calling one still fails at
  // the call site.
  var CALLS = {
    'downloads.download': bridged('downloads.download'),
    'downloads.search': bridged('downloads.search'),
    'downloads.cancel': bridged('downloads.cancel'),
    'downloads.erase': bridged('downloads.erase'),
    'downloads.open': bridged('downloads.open'),
    'downloads.show': bridged('downloads.show'),
    'downloads.pause': bridged('downloads.pause'),
    'downloads.resume': bridged('downloads.resume'),
    'idle.queryState': bridged('idle.queryState'),
  };

  // Events on namespaces zer0 answers, which exist and never fire.
  //
  // The same tier-2 bargain as everywhere else in this file, and the same cost:
  // an extension whose only road is `downloads.onChanged` now starts and then
  // does nothing, which is better than dead and is not working. There is no
  // road from this browser to a running worker to fire them down — a worker
  // that is asleep is asleep, and holding a `fetch` open to keep one awake
  // would be this file deciding an extension may never be suspended.
  var ANSWERED_EVENTS = [
    'downloads.onCreated',
    'downloads.onChanged',
    'downloads.onErased',
    'downloads.onDeterminingFilename',
    'idle.onStateChanged',
  ];

  // `chrome.management.getSelf`, out of the extension's own manifest.
  //
  // Chrome needs no permission for this one and neither does zer0, because
  // nothing here is a fact the extension did not already hold: it is its own
  // `manifest.json` and its own id, rearranged. Everything else in
  // `chrome.management` — `getAll`, `setEnabled`, `uninstall` — stays undefined
  // and is refused on the Extensions screen in as many words: one extension does
  // not get to switch off another.
  function selfDescription() {
    var manifest = {};
    try {
      manifest = chrome.runtime.getManifest() || {};
    } catch (e) {
      return null;
    }
    return {
      id: chrome.runtime.id,
      name: manifest.name || '',
      shortName: manifest.short_name || manifest.name || '',
      description: manifest.description || '',
      version: manifest.version || '',
      versionName: manifest.version_name,
      mayDisable: true,
      enabled: true,
      installType: 'normal',
      type: 'extension',
      permissions: (manifest.permissions || []).slice(),
      hostPermissions: (manifest.host_permissions || []).slice(),
      icons: [],
      offlineEnabled: !!manifest.offline_enabled,
      optionsUrl: '',
      homepageUrl: manifest.homepage_url,
      updateUrl: manifest.update_url,
      isApp: false,
    };
  }

  function namespaceIn(root, name) {
    var existing = root[name];
    if (existing !== undefined && existing !== null) return existing;
    if (CREATABLE.indexOf(name) === -1) return null;
    try {
      root[name] = {};
    } catch (e) {
      return null;
    }
    return root[name] || null;
  }

  function define(root, path, value) {
    var dot = path.indexOf('.');
    var namespace = namespaceIn(root, path.slice(0, dot));
    if (!namespace) return;
    var member = path.slice(dot + 1);
    if (namespace[member] !== undefined) return;
    try {
      namespace[member] = value;
    } catch (e) {
      // A frozen namespace is WebKit's to decide. Nothing else to try, and
      // nothing worth reporting: the extension is exactly as it was.
    }
  }

  // `chrome.storage.managed`, empty and read-only.
  //
  // Twelve of 59 packages read it. Empty is the correct answer rather than a
  // stand-in for one: managed storage holds what an enterprise policy put
  // there, zer0 has no mechanism by which a policy could put anything there,
  // so there is nothing in it and there is no version of this browser where
  // there would be. Chrome makes it read-only too, so the rejection below is
  // Chrome's behaviour and not zer0 refusing something.
  function managedStorage() {
    // Chrome's `get` answers with the defaults it was handed, since nothing is
    // ever set. A string or an array of keys asks for values that do not exist
    // and gets an empty object.
    function readBack(keys) {
      var out = {};
      if (keys && typeof keys === 'object' && !Array.isArray(keys)) {
        for (var key in keys) {
          if (Object.prototype.hasOwnProperty.call(keys, key)) out[key] = keys[key];
        }
      }
      return out;
    }

    function answer(args, value) {
      var last = args.length ? args[args.length - 1] : undefined;
      if (typeof last === 'function') {
        last(value);
        return undefined;
      }
      return Promise.resolve(value);
    }

    function readOnly(method) {
      return function () {
        var error = new Error(
          'chrome.storage.managed is read-only, so ' + method + ' cannot change it.'
        );
        var last = arguments.length ? arguments[arguments.length - 1] : undefined;
        if (typeof last === 'function') {
          // A callback caller reads `runtime.lastError`, which this file has no
          // way to set. Throwing is the loud answer available here, and it is
          // loud at the call site rather than at startup.
          throw error;
        }
        return Promise.reject(error);
      };
    }

    return {
      get: function (keys) {
        return answer(arguments, readBack(keys));
      },
      getBytesInUse: function () {
        return answer(arguments, 0);
      },
      getKeys: function () {
        return answer(arguments, []);
      },
      set: readOnly('set'),
      remove: readOnly('remove'),
      clear: readOnly('clear'),
      onChanged: eventObject(),
    };
  }

  function apply(root) {
    if (!root) return;

    var path;
    for (path in ENUMS) {
      if (Object.prototype.hasOwnProperty.call(ENUMS, path)) define(root, path, ENUMS[path]);
    }
    for (path in CONSTANTS) {
      if (Object.prototype.hasOwnProperty.call(CONSTANTS, path)) {
        define(root, path, CONSTANTS[path]);
      }
    }
    for (var i = 0; i < EVENTS.length; i++) {
      define(root, EVENTS[i], eventObject());
    }

    // What zer0 answers itself. Guarded like everything else, so an engine that
    // ships one of these keeps its own.
    for (path in CALLS) {
      if (Object.prototype.hasOwnProperty.call(CALLS, path)) define(root, path, CALLS[path]);
    }
    for (var j = 0; j < ANSWERED_EVENTS.length; j++) {
      define(root, ANSWERED_EVENTS[j], eventObject());
    }

    // Only where the extension can be asked what it is. In a context with no
    // `chrome.runtime` there is nothing to answer out of, and a `getSelf` that
    // answered anyway would be inventing the description.
    var described = selfDescription();
    if (described) {
      define(root, 'management.getSelf', function (callback) {
        if (typeof callback === 'function') {
          callback(described);
          return undefined;
        }
        return Promise.resolve(described);
      });
    }

    // Only where `chrome.storage` is there at all. A permission the person
    // withheld leaves the whole namespace undefined (ADR-0077), and handing an
    // extension a storage it was refused would undo that decision.
    define(root, 'storage.managed', managedStorage());
  }

  var chromeRoot = typeof chrome !== 'undefined' ? chrome : null;
  var browserRoot = typeof browser !== 'undefined' ? browser : null;
  apply(chromeRoot);
  if (browserRoot && browserRoot !== chromeRoot) apply(browserRoot);
})();
