"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.sendMetric = exports.telemetryAction = void 0;
const tslib_1 = require("tslib");
const commander_1 = require("commander");
const debug_1 = tslib_1.__importDefault(require("debug"));
const colors_1 = tslib_1.__importDefault(require("./colors"));
const ipc_1 = require("./ipc");
const log_1 = require("./log");
const sysconfig_1 = require("./sysconfig");
const subprocess_1 = require("./util/subprocess");
const term_1 = require("./util/term");
const debug = (0, debug_1.default)('capacitor:telemetry');
const THANK_YOU = `\nThank you for helping improve Capacitor by sharing anonymous usage data! 💖` +
    `\nInformation about the data we collect is available on our website: ${colors_1.default.strong('https://capacitorjs.com/docs/next/cli/telemetry')}` +
    `\nYou can disable telemetry at any time by using the ${colors_1.default.input('npx cap telemetry off')} command.`;
function telemetryAction(config, action) {
    return async (...actionArgs) => {
        const start = new Date();
        // This is how commanderjs works--the command object is either the last
        // element or second to last if there are additional options (via `.allowUnknownOption()`)
        const lastArg = actionArgs[actionArgs.length - 1];
        const cmd = lastArg instanceof commander_1.Command ? lastArg : actionArgs[actionArgs.length - 2];
        const command = getFullCommandName(cmd);
        let error;
        try {
            await action(...actionArgs);
        }
        catch (e) {
            error = e;
        }
        const end = new Date();
        const duration = end.getTime() - start.getTime();
        const packages = Object.entries({
            ...config.app.package.devDependencies,
            ...config.app.package.dependencies,
        });
        // Only collect packages in the capacitor org:
        // https://www.npmjs.com/org/capacitor
        const capacitorPackages = packages.filter(([k]) => k.startsWith('@capacitor/'));
        const versions = capacitorPackages.map(([k, v]) => [
            `${k.replace(/^@capacitor\//, '').replace(/-/g, '_')}_version`,
            v,
        ]);
        const data = {
            app_id: await getAppIdentifier(config),
            command,
            arguments: cmd.args.join(' '),
            options: JSON.stringify(cmd.opts()),
            duration,
            error: error ? (error.message ? error.message : String(error)) : null,
            node_version: process.version,
            os: config.cli.os,
            ...Object.fromEntries(versions),
        };
        if ((0, term_1.isInteractive)()) {
            let sysconfig = await (0, sysconfig_1.readConfig)();
            if (!error && typeof sysconfig.telemetry === 'undefined') {
                // Telemetry is opt-out; turn telemetry on then inform the user how to opt-out.
                sysconfig = { ...sysconfig, telemetry: true };
                await (0, sysconfig_1.writeConfig)(sysconfig);
                log_1.output.write(THANK_YOU);
            }
            await sendMetric(sysconfig, 'capacitor_cli_command', data);
        }
        if (error) {
            throw error;
        }
    };
}
exports.telemetryAction = telemetryAction;
/**
 * If telemetry is enabled, send a metric via IPC to a forked process for uploading.
 */
async function sendMetric(sysconfig, name, data) {
    if (sysconfig.telemetry && (0, term_1.isInteractive)()) {
        const message = {
            name,
            timestamp: new Date().toISOString(),
            session_id: sysconfig.machine,
            source: 'capacitor_cli',
            value: data,
        };
        await (0, ipc_1.send)({ type: 'telemetry', data: message });
    }
    else {
        debug('Telemetry is off (user choice, non-interactive terminal, or CI)--not sending metric');
    }
}
exports.sendMetric = sendMetric;
/**
 * Get a unique anonymous identifier for this app.
 */
async function getAppIdentifier(config) {
    const { createHash } = await Promise.resolve().then(() => tslib_1.__importStar(require('crypto')));
    // get the first commit hash, which should be universally unique
    const output = await (0, subprocess_1.getCommandOutput)('git', ['rev-list', '--max-parents=0', 'HEAD'], { cwd: config.app.rootDir });
    const firstLine = output === null || output === void 0 ? void 0 : output.split('\n')[0];
    if (!firstLine) {
        debug('Could not obtain unique app identifier');
        return null;
    }
    // use sha1 to create a one-way hash to anonymize
    const id = createHash('sha1').update(firstLine).digest('hex');
    return id;
}
/**
 * Walk through the command's parent tree and construct a space-separated name.
 *
 * Probably overkill because we don't have nested commands, but whatever.
 */
function getFullCommandName(cmd) {
    const names = [];
    while (cmd.parent !== null) {
        names.push(cmd.name());
        cmd = cmd.parent;
    }
    return names.reverse().join(' ');
}
