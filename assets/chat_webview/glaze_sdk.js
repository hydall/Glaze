(function() {
  if (window.glaze && window.glaze.__version) return;

  const nextId = (() => {
    let counter = 0;
    return () => `glaze_${Date.now()}_${++counter}`;
  })();

  function makeError(message, code) {
    const error = new Error(message || 'Glaze bridge error');
    if (code) error.code = code;
    return error;
  }

  async function callBridge(method, params) {
    if (!method || typeof method !== 'string') {
      throw makeError('glaze bridge method is required', 'bad_method');
    }

    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      const result = await window.flutter_inappwebview.callHandler('glazeBridge', {
        id: nextId(),
        method,
        params: params || {},
        context: window.__glazeContext || {},
      });
      return unwrapResult(result);
    }

    if (window.parent && window.parent !== window) {
      return callParentBridge(method, params || {});
    }

    throw makeError('Glaze bridge is not available', 'bridge_unavailable');
  }

  function callParentBridge(method, params) {
    return new Promise((resolve, reject) => {
      const id = nextId();
      const timeout = setTimeout(() => {
        window.removeEventListener('message', onMessage);
        reject(makeError(`glaze.${method} timed out`, 'timeout'));
      }, 60000);

      function onMessage(event) {
        const data = event.data || {};
        if (!data || data.type !== 'glaze:response' || data.id !== id) return;
        clearTimeout(timeout);
        window.removeEventListener('message', onMessage);
        try {
          resolve(unwrapResult(data));
        } catch (error) {
          reject(error);
        }
      }

      window.addEventListener('message', onMessage);
      window.parent.postMessage({
        type: 'glaze:request',
        id,
        method,
        params,
        context: window.__glazeContext || {},
      }, '*');
    });
  }

  function unwrapResult(result) {
    if (typeof result === 'string') {
      try { result = JSON.parse(result); } catch (_) { return result; }
    }
    if (!result || typeof result !== 'object') return result;
    if (result.ok === false) {
      const error = result.error || {};
      throw makeError(error.message || String(error), error.code);
    }
    if (Object.prototype.hasOwnProperty.call(result, 'result')) return result.result;
    return result;
  }

  function normalizeScope(scope) {
    if (!scope) return 'chat';
    return String(scope);
  }

  window.glaze = Object.freeze({
    __version: '0.1.0',
    bridge: callBridge,
    getVariables(scope, path) {
      return callBridge('getVariables', { scope: normalizeScope(scope), path });
    },
    setVariables(scope, pathOrValues, value) {
      if (typeof pathOrValues === 'string') {
        return callBridge('setVariables', { scope: normalizeScope(scope), path: pathOrValues, value });
      }
      return callBridge('setVariables', { scope: normalizeScope(scope), values: pathOrValues || {} });
    },
    deleteVariable(scope, path) {
      return callBridge('deleteVariable', { scope: normalizeScope(scope), path });
    },
    executeCommand(command, args) {
      return callBridge('executeCommand', { command, args: args || {} });
    },
    triggerGeneration(options) {
      return callBridge('triggerGeneration', options || {});
    },
    injectPrompt(id, content, options) {
      return callBridge('injectPrompt', { id, content, options: options || {} });
    },
    uninjectPrompt(id) {
      return callBridge('uninjectPrompt', { id });
    },
    generateText(prompt, options) {
      return callBridge('generateText', { prompt, options: options || {} });
    },
    showToast(message, options) {
      return callBridge('showToast', { message, options: options || {} });
    },
    playAudio(source, options) {
      return callBridge('playAudio', { source, options: options || {} });
    },
  });
})();
