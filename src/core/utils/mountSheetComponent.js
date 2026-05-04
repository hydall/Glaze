import { createApp, h } from 'vue';

export function mountSheetComponent(component, props = {}) {
    const container = document.createElement('div');
    const app = createApp({
        render() {
            return h(component, props);
        }
    });
    app.mount(container);
    return {
        el: container.firstElementChild || container,
        unmount() {
            app.unmount();
        }
    };
}
