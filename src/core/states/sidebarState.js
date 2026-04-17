import { reactive } from 'vue';

export const sidebarState = reactive({
    isOccupied: false,
    activeSheetId: null
});

export function setSidebarOccupied(occupied, sheetId = null) {
    sidebarState.isOccupied = occupied;
    sidebarState.activeSheetId = occupied ? sheetId : null;
}
