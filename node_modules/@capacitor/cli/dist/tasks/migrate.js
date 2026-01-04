"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.migrateCommand = void 0;
const tslib_1 = require("tslib");
const fs_extra_1 = require("fs-extra");
const path_1 = require("path");
const rimraf_1 = require("rimraf");
const semver_1 = require("semver");
const colors_1 = tslib_1.__importDefault(require("../colors"));
const common_1 = require("../common");
const errors_1 = require("../errors");
const common_2 = require("../ios/common");
const log_1 = require("../log");
const fs_1 = require("../util/fs");
const spm_1 = require("../util/spm");
const subprocess_1 = require("../util/subprocess");
const template_1 = require("../util/template");
// eslint-disable-next-line prefer-const
let allDependencies = {};
const libs = ['@capacitor/core', '@capacitor/cli', '@capacitor/ios', '@capacitor/android'];
const plugins = [
    '@capacitor/action-sheet',
    '@capacitor/app',
    '@capacitor/app-launcher',
    '@capacitor/browser',
    '@capacitor/camera',
    '@capacitor/clipboard',
    '@capacitor/device',
    '@capacitor/dialog',
    '@capacitor/filesystem',
    '@capacitor/geolocation',
    '@capacitor/google-maps',
    '@capacitor/haptics',
    '@capacitor/keyboard',
    '@capacitor/local-notifications',
    '@capacitor/motion',
    '@capacitor/network',
    '@capacitor/preferences',
    '@capacitor/push-notifications',
    '@capacitor/screen-orientation',
    '@capacitor/screen-reader',
    '@capacitor/share',
    '@capacitor/splash-screen',
    '@capacitor/status-bar',
    '@capacitor/text-zoom',
    '@capacitor/toast',
];
const coreVersion = '^8.0.0';
const pluginVersion = '^8.0.0';
const gradleVersion = '8.14.3';
const iOSVersion = '15';
const kotlinVersion = '2.2.20';
let installFailed = false;
async function migrateCommand(config, noprompt, packagemanager) {
    if (config === null) {
        (0, errors_1.fatal)('Config data missing');
    }
    const capMajor = await checkCapacitorMajorVersion(config);
    if (capMajor < 7) {
        (0, errors_1.fatal)('Migrate can only be used on Capacitor 7, please use the CLI in Capacitor 7 to upgrade to 7 first');
    }
    const jdkMajor = await (0, common_1.checkJDKMajorVersion)();
    if (jdkMajor < 21) {
        log_1.logger.warn('Capacitor 8 requires JDK 21 or higher. Some steps may fail.');
    }
    const variablesAndClasspaths = await getAndroidVariablesAndClasspaths(config);
    if (!variablesAndClasspaths) {
        (0, errors_1.fatal)('Variable and Classpath info could not be read.');
    }
    allDependencies = {
        ...config.app.package.dependencies,
        ...config.app.package.devDependencies,
    };
    const monorepoWarning = 'Please note this tool is not intended for use in a mono-repo environment, you should migrate manually instead. Refer to https://capacitorjs.com/docs/next/updating/8-0';
    log_1.logger.info(monorepoWarning);
    const { migrateconfirm } = noprompt
        ? { migrateconfirm: 'y' }
        : await (0, log_1.logPrompt)(`Capacitor 8 sets a deployment target of iOS ${iOSVersion} and Android 16 (SDK 36). \n`, {
            type: 'text',
            name: 'migrateconfirm',
            message: `Are you sure you want to migrate? (Y/n)`,
            initial: 'y',
        });
    if (typeof migrateconfirm === 'string' && migrateconfirm.toLowerCase() === 'y') {
        try {
            const { depInstallConfirm } = noprompt
                ? { depInstallConfirm: 'y' }
                : await (0, log_1.logPrompt)(`Would you like the migrator to run npm, yarn, pnpm, or bun install to install the latest versions of capacitor packages? (Those using other package managers should answer N)`, {
                    type: 'text',
                    name: 'depInstallConfirm',
                    message: `Run Dependency Install? (Y/n)`,
                    initial: 'y',
                });
            const runNpmInstall = typeof depInstallConfirm === 'string' && depInstallConfirm.toLowerCase() === 'y';
            let installerType = 'npm';
            if (runNpmInstall) {
                const { manager } = packagemanager
                    ? { manager: packagemanager }
                    : await (0, log_1.logPrompt)('What dependency manager do you use?', {
                        type: 'select',
                        name: 'manager',
                        message: `Dependency Management Tool`,
                        choices: [
                            { title: 'NPM', value: 'npm' },
                            { title: 'Yarn', value: 'yarn' },
                            { title: 'PNPM', value: 'pnpm' },
                            { title: 'Bun', value: 'bun' },
                        ],
                        initial: 0,
                    });
                installerType = manager;
            }
            try {
                await (0, common_1.runTask)(`Installing Latest Modules using ${installerType}.`, () => {
                    return installLatestLibs(installerType, runNpmInstall, config);
                });
            }
            catch (ex) {
                log_1.logger.error(`${installerType} install failed. Try deleting node_modules folder and running ${colors_1.default.input(`${installerType} install --force`)} manually.`);
                installFailed = true;
            }
            // Update iOS Projects
            if (allDependencies['@capacitor/ios'] && (0, fs_extra_1.existsSync)(config.ios.platformDirAbs)) {
                const currentiOSVersion = (0, common_2.getMajoriOSVersion)(config);
                if (parseInt(currentiOSVersion) < parseInt(iOSVersion)) {
                    // ios template changes
                    await (0, common_1.runTask)(`Migrating deployment target to ${iOSVersion}.0.`, () => {
                        return updateFile(config, (0, path_1.join)(config.ios.nativeXcodeProjDirAbs, 'project.pbxproj'), 'IPHONEOS_DEPLOYMENT_TARGET = ', ';', `${iOSVersion}.0`);
                    });
                    if ((await (0, spm_1.checkPackageManager)(config)) === 'Cocoapods') {
                        // Update Podfile
                        await (0, common_1.runTask)(`Migrating Podfile to ${iOSVersion}.0.`, () => {
                            return updateFile(config, (0, path_1.join)(config.ios.nativeProjectDirAbs, 'Podfile'), `platform :ios, '`, `'`, `${iOSVersion}.0`);
                        });
                    }
                }
                else {
                    log_1.logger.warn('Skipped updating deployment target');
                }
            }
            if (!installFailed) {
                await (0, common_1.runTask)(`Running cap sync.`, () => {
                    return (0, subprocess_1.runCommand)('npx', ['cap', 'sync']);
                });
            }
            else {
                log_1.logger.warn('Skipped Running cap sync.');
            }
            if (allDependencies['@capacitor/android'] && (0, fs_extra_1.existsSync)(config.android.platformDirAbs)) {
                // AndroidManifest.xml add "density"
                await (0, common_1.runTask)(`Migrating AndroidManifest.xml by adding density to Activity configChanges.`, () => {
                    return updateAndroidManifest((0, path_1.join)(config.android.srcMainDirAbs, 'AndroidManifest.xml'));
                });
                const gradleWrapperVersion = getGradleWrapperVersion((0, path_1.join)(config.android.platformDirAbs, 'gradle', 'wrapper', 'gradle-wrapper.properties'));
                if (!installFailed && (0, semver_1.gte)(gradleVersion, gradleWrapperVersion)) {
                    try {
                        await (0, common_1.runTask)(`Upgrading gradle wrapper`, () => {
                            return updateGradleWrapperFiles(config.android.platformDirAbs);
                        });
                        // Run twice as first time it only updates the wrapper properties file
                        await (0, common_1.runTask)(`Upgrading gradle wrapper files`, () => {
                            return updateGradleWrapperFiles(config.android.platformDirAbs);
                        });
                    }
                    catch (e) {
                        if (e.includes('EACCES')) {
                            log_1.logger.error(`gradlew file does not have executable permissions. This can happen if the Android platform was added on a Windows machine. Please run ${colors_1.default.input(`chmod +x ./${config.android.platformDir}/gradlew`)} and ${colors_1.default.input(`cd ${config.android.platformDir} && ./gradlew wrapper --distribution-type all --gradle-version ${gradleVersion} --warning-mode all`)} to update the files manually`);
                        }
                        else {
                            log_1.logger.error(`gradle wrapper files were not updated`);
                        }
                    }
                }
                else {
                    log_1.logger.warn('Skipped upgrading gradle wrapper files');
                }
                await (0, common_1.runTask)(`Migrating root build.gradle file.`, () => {
                    return updateBuildGradle((0, path_1.join)(config.android.platformDirAbs, 'build.gradle'), variablesAndClasspaths);
                });
                await (0, common_1.runTask)(`Migrating app build.gradle file.`, () => {
                    return updateAppBuildGradle((0, path_1.join)(config.android.appDirAbs, 'build.gradle'));
                });
                // Variables gradle
                await (0, common_1.runTask)(`Migrating variables.gradle file.`, () => {
                    return (async () => {
                        const variablesPath = (0, path_1.join)(config.android.platformDirAbs, 'variables.gradle');
                        let txt = readFile(variablesPath);
                        if (!txt) {
                            return;
                        }
                        txt = txt.replace(/= {2}'/g, `= '`);
                        (0, fs_extra_1.writeFileSync)(variablesPath, txt, { encoding: 'utf-8' });
                        for (const variable of Object.keys(variablesAndClasspaths.variables)) {
                            let replaceStart = `${variable} = '`;
                            let replaceEnd = `'\n`;
                            if (typeof variablesAndClasspaths.variables[variable] === 'number') {
                                replaceStart = `${variable} = `;
                                replaceEnd = `\n`;
                            }
                            if (txt.includes(replaceStart)) {
                                const first = txt.indexOf(replaceStart) + replaceStart.length;
                                const value = txt.substring(first, txt.indexOf(replaceEnd, first));
                                if ((typeof variablesAndClasspaths.variables[variable] === 'number' &&
                                    value <= variablesAndClasspaths.variables[variable]) ||
                                    (typeof variablesAndClasspaths.variables[variable] === 'string' &&
                                        (0, semver_1.lt)(value, variablesAndClasspaths.variables[variable]))) {
                                    await updateFile(config, variablesPath, replaceStart, replaceEnd, variablesAndClasspaths.variables[variable].toString(), true);
                                }
                            }
                            else {
                                let file = readFile(variablesPath);
                                if (file) {
                                    file = file.replace('}', `    ${replaceStart}${variablesAndClasspaths.variables[variable].toString()}${replaceEnd}}`);
                                    (0, fs_extra_1.writeFileSync)(variablesPath, file);
                                }
                            }
                        }
                        const pluginVariables = {
                            firebaseMessagingVersion: '25.0.1',
                            playServicesLocationVersion: '21.3.0',
                            androidxBrowserVersion: '1.9.0',
                            androidxMaterialVersion: '1.13.0',
                            androidxExifInterfaceVersion: '1.4.1',
                            androidxCoreKTXVersion: '1.17.0',
                            googleMapsPlayServicesVersion: '19.2.0',
                            googleMapsUtilsVersion: '3.19.1',
                            googleMapsKtxVersion: '5.2.1',
                            googleMapsUtilsKtxVersion: '5.2.1',
                            kotlinxCoroutinesVersion: '1.10.2',
                            coreSplashScreenVersion: '1.2.0',
                        };
                        for (const variable of Object.keys(pluginVariables)) {
                            await updateFile(config, variablesPath, `${variable} = '`, `'`, pluginVariables[variable], true);
                        }
                    })();
                });
                rimraf_1.rimraf.sync((0, path_1.join)(config.android.appDirAbs, 'build'));
            }
            // Write all breaking changes
            await (0, common_1.runTask)(`Writing breaking changes.`, () => {
                return writeBreakingChanges();
            });
            if (!installFailed) {
                (0, log_1.logSuccess)(`Migration to Capacitor ${coreVersion} is complete. Run and test your app!`);
            }
            else {
                log_1.logger.warn(`Migration to Capacitor ${coreVersion} is incomplete. Check the log messages for more information.`);
            }
        }
        catch (err) {
            (0, errors_1.fatal)(`Failed to migrate: ${err}`);
        }
    }
    else {
        (0, errors_1.fatal)(`User canceled migration.`);
    }
}
exports.migrateCommand = migrateCommand;
async function checkCapacitorMajorVersion(config) {
    var _a;
    const capacitorVersion = await (0, common_1.getCoreVersion)(config);
    const versionArray = (_a = capacitorVersion.match(/([0-9]+)\.([0-9]+)\.([0-9]+)/)) !== null && _a !== void 0 ? _a : [];
    const majorVersion = parseInt(versionArray[1]);
    return majorVersion;
}
async function installLatestLibs(dependencyManager, runInstall, config) {
    const pkgJsonPath = (0, path_1.join)(config.app.rootDir, 'package.json');
    const pkgJsonFile = readFile(pkgJsonPath);
    if (!pkgJsonFile) {
        return;
    }
    const pkgJson = JSON.parse(pkgJsonFile);
    for (const devDepKey of Object.keys(pkgJson['devDependencies'] || {})) {
        if (libs.includes(devDepKey)) {
            pkgJson['devDependencies'][devDepKey] = coreVersion;
        }
        else if (plugins.includes(devDepKey)) {
            pkgJson['devDependencies'][devDepKey] = pluginVersion;
        }
    }
    for (const depKey of Object.keys(pkgJson['dependencies'] || {})) {
        if (libs.includes(depKey)) {
            pkgJson['dependencies'][depKey] = coreVersion;
        }
        else if (plugins.includes(depKey)) {
            pkgJson['dependencies'][depKey] = pluginVersion;
        }
    }
    (0, fs_extra_1.writeFileSync)(pkgJsonPath, JSON.stringify(pkgJson, null, 2), {
        encoding: 'utf-8',
    });
    if (runInstall) {
        rimraf_1.rimraf.sync((0, path_1.join)(config.app.rootDir, 'node_modules/@capacitor/!(cli)'));
        await (0, subprocess_1.runCommand)(dependencyManager, ['install']);
        if (dependencyManager == 'yarn') {
            await (0, subprocess_1.runCommand)(dependencyManager, ['upgrade']);
        }
        else {
            await (0, subprocess_1.runCommand)(dependencyManager, ['update']);
        }
    }
    else {
        log_1.logger.info(`Please run an install command with your package manager of choice. (ex: yarn install)`);
    }
}
async function writeBreakingChanges() {
    const breaking = [
        '@capacitor/action-sheet',
        '@capacitor/barcode-scanner',
        '@capacitor/browser',
        '@capacitor/camera',
        '@capacitor/geolocation',
        '@capacitor/google-maps',
        '@capacitor/push-notifications',
        '@capacitor/screen-orientation',
        '@capacitor/splash-screen',
        '@capacitor/status-bar',
    ];
    const broken = [];
    for (const lib of breaking) {
        if (allDependencies[lib]) {
            broken.push(lib);
        }
    }
    if (broken.length > 0) {
        log_1.logger.info(`IMPORTANT: Review https://capacitorjs.com/docs/next/updating/8-0#plugins for breaking changes in these plugins that you use: ${broken.join(', ')}.`);
    }
}
async function getAndroidVariablesAndClasspaths(config) {
    const tempAndroidTemplateFolder = (0, path_1.join)(config.cli.assetsDirAbs, 'tempAndroidTemplate');
    await (0, template_1.extractTemplate)(config.cli.assets.android.platformTemplateArchiveAbs, tempAndroidTemplateFolder);
    const variablesGradleFile = readFile((0, path_1.join)(tempAndroidTemplateFolder, 'variables.gradle'));
    const buildGradleFile = readFile((0, path_1.join)(tempAndroidTemplateFolder, 'build.gradle'));
    if (!variablesGradleFile || !buildGradleFile) {
        return;
    }
    (0, fs_1.deleteFolderRecursive)(tempAndroidTemplateFolder);
    const firstIndxOfCATBGV = buildGradleFile.indexOf(`classpath 'com.android.tools.build:gradle:`) + 42;
    const firstIndxOfCGGGS = buildGradleFile.indexOf(`com.google.gms:google-services:`) + 31;
    const comAndroidToolsBuildGradleVersion = '' + buildGradleFile.substring(firstIndxOfCATBGV, buildGradleFile.indexOf("'", firstIndxOfCATBGV));
    const comGoogleGmsGoogleServices = '' + buildGradleFile.substring(firstIndxOfCGGGS, buildGradleFile.indexOf("'", firstIndxOfCGGGS));
    const variablesGradleAsJSON = JSON.parse(variablesGradleFile
        .replace('ext ', '')
        .replace(/=/g, ':')
        .replace(/\n/g, ',')
        .replace(/,([^:]+):/g, function (_k, p1) {
        return `,"${p1}":`;
    })
        .replace('{,', '{')
        .replace(',}', '}')
        .replace(/\s/g, '')
        .replace(/'/g, '"'));
    return {
        variables: variablesGradleAsJSON,
        'com.android.tools.build:gradle': comAndroidToolsBuildGradleVersion,
        'com.google.gms:google-services': comGoogleGmsGoogleServices,
    };
}
function readFile(filename) {
    try {
        if (!(0, fs_extra_1.existsSync)(filename)) {
            log_1.logger.error(`Unable to find ${filename}. Try updating it manually`);
            return;
        }
        return (0, fs_extra_1.readFileSync)(filename, 'utf-8');
    }
    catch (err) {
        log_1.logger.error(`Unable to read ${filename}. Verify it is not already open. ${err}`);
    }
}
function getGradleWrapperVersion(filename) {
    var _a;
    const txt = readFile(filename);
    if (!txt) {
        return '0.0.0';
    }
    const version = txt.substring(txt.indexOf('gradle-') + 7, txt.indexOf('-all.zip'));
    const semverVersion = (_a = (0, semver_1.coerce)(version)) === null || _a === void 0 ? void 0 : _a.version;
    return semverVersion ? semverVersion : '0.0.0';
}
async function updateGradleWrapperFiles(platformDir) {
    await (0, subprocess_1.runCommand)(`./gradlew`, ['wrapper', '--distribution-type', 'all', '--gradle-version', gradleVersion, '--warning-mode', 'all'], {
        cwd: platformDir,
    });
}
async function updateBuildGradle(filename, variablesAndClasspaths) {
    const txt = readFile(filename);
    if (!txt) {
        return;
    }
    const neededDeps = {
        'com.android.tools.build:gradle': variablesAndClasspaths['com.android.tools.build:gradle'],
        'com.google.gms:google-services': variablesAndClasspaths['com.google.gms:google-services'],
    };
    let replaced = txt;
    for (const dep of Object.keys(neededDeps)) {
        if (replaced.includes(`classpath '${dep}`)) {
            const firstIndex = replaced.indexOf(dep) + dep.length + 1;
            const existingVersion = '' + replaced.substring(firstIndex, replaced.indexOf("'", firstIndex));
            if ((0, semver_1.gte)(neededDeps[dep], existingVersion)) {
                replaced = setAllStringIn(replaced, `classpath '${dep}:`, `'`, neededDeps[dep]);
                log_1.logger.info(`Set ${dep} = ${neededDeps[dep]}.`);
            }
        }
    }
    const beforeKotlinVersionUpdate = replaced;
    replaced = replaceVersion(replaced, /(ext\.kotlin_version\s*=\s*['"])([^'"]+)(['"])/, kotlinVersion);
    replaced = replaceVersion(replaced, /(org\.jetbrains\.kotlin:kotlin[^:]*:)([\d.]+)(['"])/, kotlinVersion);
    if (beforeKotlinVersionUpdate !== replaced) {
        log_1.logger.info(`Set Kotlin version to ${kotlinVersion}`);
    }
    (0, fs_extra_1.writeFileSync)(filename, replaced, 'utf-8');
}
function replaceVersion(text, regex, newVersion) {
    return text.replace(regex, (match, prefix, currentVersion, suffix) => {
        var _a;
        const semVer = (_a = (0, semver_1.coerce)(currentVersion)) === null || _a === void 0 ? void 0 : _a.version;
        if ((0, semver_1.gte)(newVersion, semVer ? semVer : '0.0.0')) {
            return `${prefix || ''}${newVersion}${suffix || ''}`;
        }
        return match;
    });
}
async function updateAppBuildGradle(filename) {
    const txt = readFile(filename);
    if (!txt) {
        return;
    }
    let replaced = txt;
    const gradlePproperties = ['compileSdk', 'namespace', 'ignoreAssetsPattern'];
    for (const prop of gradlePproperties) {
        // Use updated Groovy DSL syntax with " = " assignment
        const regex = new RegExp(`(^\\s*${prop})\\s+(?!=)(.+)$`, 'gm');
        replaced = replaced.replace(regex, (_match, key, value) => {
            return `${key} = ${value.trim()}`;
        });
    }
    (0, fs_extra_1.writeFileSync)(filename, replaced, 'utf-8');
}
async function updateFile(config, filename, textStart, textEnd, replacement, skipIfNotFound) {
    if (config === null) {
        return false;
    }
    const path = filename;
    let txt = readFile(path);
    if (!txt) {
        return false;
    }
    if (txt.includes(textStart)) {
        if (replacement) {
            txt = setAllStringIn(txt, textStart, textEnd, replacement);
            (0, fs_extra_1.writeFileSync)(path, txt, { encoding: 'utf-8' });
        }
        else {
            // Replacing in code so we need to count the number of brackets to find the end of the function in swift
            const lines = txt.split('\n');
            let replaced = '';
            let keep = true;
            let brackets = 0;
            for (const line of lines) {
                if (line.includes(textStart)) {
                    keep = false;
                }
                if (!keep) {
                    brackets += (line.match(/{/g) || []).length;
                    brackets -= (line.match(/}/g) || []).length;
                    if (brackets == 0) {
                        keep = true;
                    }
                }
                else {
                    replaced += line + '\n';
                }
            }
            (0, fs_extra_1.writeFileSync)(path, replaced, { encoding: 'utf-8' });
        }
        return true;
    }
    else if (!skipIfNotFound) {
        log_1.logger.error(`Unable to find "${textStart}" in ${filename}. Try updating it manually`);
    }
    return false;
}
function setAllStringIn(data, start, end, replacement) {
    let position = 0;
    let result = data;
    let replaced = true;
    while (replaced) {
        const foundIdx = result.indexOf(start, position);
        if (foundIdx == -1) {
            replaced = false;
        }
        else {
            const idx = foundIdx + start.length;
            position = idx + replacement.length;
            result = result.substring(0, idx) + replacement + result.substring(result.indexOf(end, idx));
        }
    }
    return result;
}
async function updateAndroidManifest(filename) {
    const txt = readFile(filename);
    if (!txt) {
        return;
    }
    if (txt.includes('|density') || txt.includes('density|')) {
        return; // Probably already updated
    }
    // Since navigation was an optional change in Capacitor 7, attempting to add density and/or navigation
    const replaced = txt
        .replace('android:configChanges="orientation|keyboardHidden|keyboard|screenSize|locale|smallestScreenSize|screenLayout|uiMode|navigation"', 'android:configChanges="orientation|keyboardHidden|keyboard|screenSize|locale|smallestScreenSize|screenLayout|uiMode|navigation|density"')
        .replace('android:configChanges="orientation|keyboardHidden|keyboard|screenSize|locale|smallestScreenSize|screenLayout|uiMode"', 'android:configChanges="orientation|keyboardHidden|keyboard|screenSize|locale|smallestScreenSize|screenLayout|uiMode|navigation|density"');
    if (!replaced.includes('|density')) {
        log_1.logger.error(`Unable to add 'density' to 'android:configChanges' in ${filename}. Try adding it manually`);
    }
    else {
        (0, fs_extra_1.writeFileSync)(filename, replaced, 'utf-8');
    }
}
