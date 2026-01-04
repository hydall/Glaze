import { registerPlugin } from '@capacitor/core';
const BackgroundMode = registerPlugin('BackgroundMode', {
    web: () => import('./web').then(m => new m.BackgroundModeWeb()),
});
export * from './definitions';
export { BackgroundMode };
//# sourceMappingURL=index.js.map