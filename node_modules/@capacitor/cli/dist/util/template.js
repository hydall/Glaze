"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.extractTemplate = void 0;
const tslib_1 = require("tslib");
const fs_extra_1 = require("fs-extra");
const tar_1 = tslib_1.__importDefault(require("tar"));
async function extractTemplate(src, dir) {
    await (0, fs_extra_1.mkdirp)(dir);
    await tar_1.default.extract({ file: src, cwd: dir });
}
exports.extractTemplate = extractTemplate;
