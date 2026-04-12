import { ref } from 'vue';
import { logger } from '../../utils/logger.js';

const savedLang = localStorage.getItem('gz_lang');
const systemLang = (navigator.language || 'en').toLowerCase().startsWith('ru') ? 'ru' : 'en';
export const currentLang = ref(savedLang || systemLang);

export function setLanguage(lang) {
    currentLang.value = lang;
    localStorage.setItem('gz_lang', lang);
}

export const imageViewerMode = ref(localStorage.getItem('gz_image_viewer') || 'default');
logger.debug('[APPSettings] Initial imageViewerMode:', imageViewerMode.value);

export function setImageViewerMode(mode) {
    logger.debug('[APPSettings] setImageViewerMode:', mode);
    imageViewerMode.value = mode;
    localStorage.setItem('gz_image_viewer', mode);
}

export const disableSwipeRegeneration = ref(localStorage.getItem('gz_disable_swipe_regeneration') === 'true');

export function setDisableSwipeRegeneration(value) {
    disableSwipeRegeneration.value = value;
    localStorage.setItem('gz_disable_swipe_regeneration', value);
}

export const hideMessageId = ref(localStorage.getItem('gz_hide_msg_id') === 'true');
export function setHideMessageId(value) {
    hideMessageId.value = value;
    localStorage.setItem('gz_hide_msg_id', value);
}

export const hideGenerationTime = ref(localStorage.getItem('gz_hide_gen_time') === 'true');
export function setHideGenerationTime(value) {
    hideGenerationTime.value = value;
    localStorage.setItem('gz_hide_gen_time', value);
}

export const hideTokenCount = ref(localStorage.getItem('gz_hide_token_count') === 'true');
export function setHideTokenCount(value) {
    hideTokenCount.value = value;
    localStorage.setItem('gz_hide_token_count', value);
}

export const enterToSubmit = ref(localStorage.getItem('gz_enter_to_submit') !== 'false');
export function setEnterToSubmit(value) {
    enterToSubmit.value = value;
    localStorage.setItem('gz_enter_to_submit', value);
}

export const hideHelpTips = ref(localStorage.getItem('gz_hide_help_tips') === 'true');
export function setHideHelpTips(value) {
    hideHelpTips.value = value;
    localStorage.setItem('gz_hide_help_tips', value);
}

export const dialogGrouping = ref(localStorage.getItem('gz_dialog_grouping') === 'true');
export function setDialogGrouping(value) {
    dialogGrouping.value = value;
    localStorage.setItem('gz_dialog_grouping', value);
}
