import { Bridge } from './chat_bridge_controller.js';
import { Formatter } from '../formatter/index.js';
import { Renderer } from '../renderer/index.js';

export { Bridge } from './chat_bridge_controller.js';
export { EditController } from './edit_controller.js';
export { GenTimer } from './gen_timer.js';
export { ImgGenTimer } from './imggen_timer.js';
export { InteractionDispatch } from './interaction_dispatch.js';
export { MessageUpdateBatcher } from './message_update_batcher.js';
export { PanelHost } from './panel_host.js';
export { SelectionManager } from './selection_manager.js';
export { SwipeGestureHandler } from './swipe_gesture_handler.js';

window.Bridge = Bridge;

window.onerror = function(msg, src, line, col, err) {
  document.title = 'JS_ERR: ' + msg + ' @' + line;
  console.error('JS_ERR:', msg, src, line, err);
};

try {
  const container = document.getElementById('chat-container');
  const formatter = new Formatter();
  const virtualList = new UseVirtualScroll(container);
  const renderer = new Renderer(formatter, virtualList);
  window.bridge = new Bridge(renderer, virtualList);
  container.addEventListener('wheel', (e) => {
    if (e.deltaMode === 0) {
      e.preventDefault();
      container.scrollTop += e.deltaY * 0.3;
    } else if (e.deltaMode === 1) {
      e.preventDefault();
      container.scrollTop += e.deltaY * 16;
    }
  }, { passive: false });
  window.bridge._sendToFlutter('onWebViewReady', []);
} catch(e) {
  document.title = 'JS_ERR: ' + e.message;
  document.getElementById('loading-screen').textContent = 'Error: ' + e.message;
}
