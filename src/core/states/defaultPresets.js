import shinoJson from '@/assets/presets/shino.json';
import fawnieJson from '@/assets/presets/fawnie.json';
import microcotJson from '@/assets/presets/microcot.json';
import fawnieImg from '@/assets/presets/fawnie.jpg';
import microcotImg from '@/assets/presets/mikrokot.jpg';
import renriJson from '@/assets/presets/renri.json';
import renriImg from '@/assets/presets/renri.jpg';
import shinoImg from '@/assets/presets/shino.jpg';

import { convertSTPreset } from '@/core/services/presetImportService.js';

const shinoConverted = convertSTPreset(shinoJson, 'Shino');
shinoConverted.id = 'default_shino';
shinoConverted.image = shinoImg;
shinoConverted.author = 'Shino';
shinoConverted.authorLink = 'https://t.me/ah_ah_shino4ka';
shinoConverted.descriptionKey = 'preset_shino_desc';
shinoConverted.isFeatured = true;
shinoConverted.parseInlineReasoning = true;
shinoConverted.reasoningStart = '<thinking>';
shinoConverted.reasoningEnd = '</thinking>';
shinoConverted.createdAt = 1;

const fawnieConverted = convertSTPreset(fawnieJson, fawnieJson.name || 'Fawnie v3');
fawnieConverted.id = 'default_fawnie';
fawnieConverted.image = fawnieImg;
fawnieConverted.author = 'fawn1e';
fawnieConverted.authorLink = 'https://t.me/dearfawwn';
fawnieConverted.descriptionKey = 'preset_fawnie_desc';
fawnieConverted.isFeatured = true;
fawnieConverted.createdAt = 2;

const microcotConverted = convertSTPreset(microcotJson, microcotJson.name || 'MicroCot Talks Mini');
microcotConverted.id = 'default_microcot';
microcotConverted.image = microcotImg;
microcotConverted.author = 'MicroCoT';
microcotConverted.authorLink = 'https://t.me/sillytavern1';
microcotConverted.descriptionKey = 'preset_microcot_desc';
microcotConverted.isFeatured = true;
microcotConverted.createdAt = 3;

const renriConverted = convertSTPreset(renriJson, renriJson.name || 'Renri');
renriConverted.id = 'default_renri';
renriConverted.image = renriImg;
renriConverted.author = 'nimda trashcan';
renriConverted.descriptionKey = 'preset_renri_desc';
renriConverted.isFeatured = true;
renriConverted.createdAt = 4;

export const userDefaultPresets = {
    'default_shino': shinoConverted,
    'default_fawnie': fawnieConverted,
    'default_microcot': microcotConverted,
    'default_renri': renriConverted
};
