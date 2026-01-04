var capacitorBackgroundMode = (function (exports, core) {
    'use strict';

    const BackgroundMode = core.registerPlugin('BackgroundMode', {
        web: () => Promise.resolve().then(function () { return web; }).then(m => new m.BackgroundModeWeb()),
    });

    class BackgroundModeWeb extends core.WebPlugin {
        async enable() {
            throw this.unimplemented('Not implemented on web.');
        }
        async disable() {
            throw this.unimplemented('Not implemented on web.');
        }
        async getSettings() {
            throw this.unimplemented('Not implemented on web.');
        }
        async updateNotification() {
            throw this.unimplemented('Not implemented on web.');
        }
        async checkNotificationsPermission() {
            throw this.unimplemented('Not implemented on web.');
        }
        async requestNotificationsPermission() {
            throw this.unimplemented('Not implemented on web.');
        }
        async checkMicrophonePermission() {
            throw this.unimplemented('Not implemented on web.');
        }
        async requestMicrophonePermission() {
            throw this.unimplemented('Not implemented on web.');
        }
        async checkBatteryOptimizations() {
            throw this.unimplemented('Not implemented on web.');
        }
        async requestDisableBatteryOptimizations() {
            throw this.unimplemented('Not implemented on web.');
        }
        async enableWebViewOptimizations() {
            throw this.unimplemented('Not implemented on web.');
        }
        async disableWebViewOptimizations() {
            throw this.unimplemented('Not implemented on web.');
        }
        async moveToBackground() {
            throw this.unimplemented('Not implemented on web.');
        }
        async moveToForeground() {
            throw this.unimplemented('Not implemented on web.');
        }
        async isScreenOff() {
            throw this.unimplemented('Not implemented on web.');
        }
        async isEnabled() {
            throw this.unimplemented('Not implemented on web.');
        }
        async isActive() {
            throw this.unimplemented('Not implemented on web.');
        }
        async wakeUp() {
            throw this.unimplemented('Not implemented on web.');
        }
        async unlock() {
            throw this.unimplemented('Not implemented on web.');
        }
    }

    var web = /*#__PURE__*/Object.freeze({
        __proto__: null,
        BackgroundModeWeb: BackgroundModeWeb
    });

    exports.BackgroundMode = BackgroundMode;

    return exports;

})({}, capacitorExports);
//# sourceMappingURL=plugin.js.map
