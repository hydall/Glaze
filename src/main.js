import { initGlobalErrorHandling } from './utils/errors.js';
import { createApp } from 'vue';
import App from './App.vue';
import './assets/styles.css';

initGlobalErrorHandling();

const app = createApp(App);

app.config.errorHandler = (err, vm, info) => {
    console.error('[Vue Error]', err, info);
    window.dispatchEvent(
        new CustomEvent('vue-error', { detail: { err, info } })
    );
};

app.mount('#app');
