/* Extracted from ../bridge.legacy.js. Keep public behavior stable. */

export class PanelHost {
  constructor(bridge) {
    this.bridge = bridge;
    this._panels = new Map();
    this._nextId = 1;
    this._setupListener();
  }

  _setupListener() {
    this._onMessage = (e) => {
      if (!e.source) return;
      for (const [panelId, panel] of this._panels) {
        if (e.source !== panel.iframe.contentWindow) continue;
        const data = e.data || {};
        if (data.type === 'glaze:panel-ready') {
          panel.ready = true;
          this.bridge._sendToFlutter('onPanelEvent', [
            JSON.stringify({ panelId, event: 'ready' }),
          ]);
          return;
        }
        if (data.type === 'glaze:panel-resize') {
          const height = Math.max(0, Math.round(Number(data.height) || 0));
          panel.lastHeight = height;
          this.bridge._sendToFlutter('onPanelResize', [
            JSON.stringify({ panelId, height }),
          ]);
          return;
        }
        if (data.type === 'glaze:panel-action') {
          this.bridge._sendToFlutter('onPanelEvent', [
            JSON.stringify({
              panelId,
              event: data.event || 'action',
              payload: data.payload || {},
            }),
          ]);
          return;
        }
        if (data.type === 'glaze:panel-close') {
          this.close(panelId);
          return;
        }
        if (data.type === 'glaze:request') {
          this._relayGlazeRequest(panel, data);
          return;
        }
      }
    };
    window.addEventListener('message', this._onMessage);
  }

  async _relayGlazeRequest(panel, data) {
    try {
      const result = await this.bridge._callGlazeBridge({
        id: data.id,
        method: data.method,
        params: data.params || {},
        // Panel identity belongs to the host, never to caller supplied options
        // or panel-controlled context.
        context: { ...(data.context || {}), panelId: panel.panelId, messageId: panel.messageId },
      });
      panel.iframe.contentWindow.postMessage(
        { type: 'glaze:response', id: data.id, ok: true, result },
        '*',
      );
    } catch (error) {
      panel.iframe.contentWindow.postMessage(
        {
          type: 'glaze:response',
          id: data.id,
          ok: false,
          error: {
            code: error && error.code,
            message: String(error && error.message ? error.message : error),
          },
        },
        '*',
      );
    }
  }

  open(messageId, html, optionsJson) {
    if (!messageId) return null;
    let options = {};
    try { options = JSON.parse(optionsJson || '{}'); } catch (_) { options = {}; }
    const section = document.querySelector(`[data-message-id="${messageId}"]`);
    if (!section) return null;

    const panelId = `panel_${this._nextId++}_${Date.now()}`;
    const host = document.createElement('div');
    host.className = 'interactive-panel';
    host.dataset.panelId = panelId;
    host.dataset.messageId = messageId;

    const placeholderHeight = Math.max(
      60,
      Math.min(2000, Number(options.minHeight) || 0),
    );
    host.style.minHeight = placeholderHeight + 'px';

    const content = section.querySelector('.msg-content') || section;
    content.appendChild(host);

    const iframe = document.createElement('iframe');
    iframe.className = 'interactive-panel-frame';
    iframe.sandbox = 'allow-scripts';
    iframe.setAttribute('aria-label', options.title || 'Interactive panel');
    iframe.style.border = '0';
    iframe.style.width = '100%';
    iframe.style.height = placeholderHeight + 'px';
    iframe.style.background = 'transparent';
    iframe.srcdoc = this._buildSrcdoc(html, options, panelId, messageId);

    host.appendChild(iframe);

    const panel = {
      panelId,
      messageId,
      host,
      iframe,
      ready: false,
      lastHeight: placeholderHeight,
      _resizeObserver: null,
    };
    this._panels.set(panelId, panel);

    if (typeof ResizeObserver !== 'undefined') {
      panel._resizeObserver = new ResizeObserver((entries) => {
        for (const entry of entries) {
          const rect = entry.contentRect;
          const height = Math.round(rect.height);
          if (height > 0 && Math.abs(height - panel.lastHeight) > 2) {
            panel.lastHeight = height;
            this.bridge._sendToFlutter('onPanelResize', [
              JSON.stringify({ panelId, height }),
            ]);
          }
        }
      });
      panel._resizeObserver.observe(host);
    }

    return panelId;
  }

  _buildSrcdoc(html, options, panelId, messageId) {
    const sdk = JSON.stringify(window.__glazeSdkSource || '');
    const userHtml = String(html == null ? '' : html);
    const context = JSON.stringify({
      messageId,
      panelId,
      title: options.title || '',
    });
    const bootstrap = `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>
<div id="glaze-panel-root">${userHtml}</div>
<script>
(function() {
  window.__glazeContext = ${context};
  var sdk = ${sdk};
  if (sdk) {
    try { (new Function(sdk))(); } catch (e) { console.error('[glaze-panel] sdk load failed', e); }
  }
  function post(type, extra) {
    parent.postMessage(Object.assign({ type: 'glaze:' + type }, extra || {}), '*');
  }
  window.glazePanel = Object.freeze({
    ready: function() { post('panel-ready'); },
    close: function() { post('panel-close'); },
    reportHeight: function(h) { post('panel-resize', { height: Number(h) || 0 }); },
    sendAction: function(event, payload) { post('panel-action', { event: event || 'action', payload: payload || {} }); },
  });
  parent.postMessage({ type: 'glaze:panel-ready' }, '*');
})();
<\/script></body></html>`;
    return bootstrap;
  }

  close(panelId) {
    const panel = this._panels.get(panelId);
    if (!panel) return;
    if (panel._resizeObserver) {
      panel._resizeObserver.disconnect();
      panel._resizeObserver = null;
    }
    if (panel.host && panel.host.parentNode) {
      panel.host.parentNode.removeChild(panel.host);
    }
    this._panels.delete(panelId);
  }

  closeAll() {
    for (const panelId of [...this._panels.keys()]) {
      this.close(panelId);
    }
  }

  postToPanel(panelId, method, paramsJson) {
    const panel = this._panels.get(panelId);
    if (!panel || !panel.iframe || !panel.iframe.contentWindow) return false;
    let params = {};
    try { params = JSON.parse(paramsJson || '{}'); } catch (_) { params = {}; }
    panel.iframe.contentWindow.postMessage({
      type: 'glaze:panel-push',
      method,
      params,
    }, '*');
    return true;
  }
}
