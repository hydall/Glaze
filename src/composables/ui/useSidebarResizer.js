import { ref } from 'vue';

export function useSidebarResizer(storageKey, defaultWidth, direction = 'left', min = 200, max = 600) {
    const width = ref(parseInt(localStorage.getItem(storageKey)) || defaultWidth);

    const startResize = (e) => {
        e.preventDefault();
        const startX = e.clientX;
        const startWidth = width.value;
        const originalCursor = document.body.style.cursor;
        document.body.style.cursor = 'col-resize';

        const onMouseMove = (moveEvent) => {
            let dx = moveEvent.clientX - startX;
            let newWidth = direction === 'left'
                ? startWidth + dx
                : startWidth - dx;

            if (newWidth < min) newWidth = min;
            if (newWidth > max) newWidth = max;
            width.value = newWidth;
        };

        const onMouseUp = () => {
            document.body.style.cursor = originalCursor;
            document.removeEventListener('mousemove', onMouseMove);
            document.removeEventListener('mouseup', onMouseUp);
            localStorage.setItem(storageKey, width.value);
        };

        document.addEventListener('mousemove', onMouseMove);
        document.addEventListener('mouseup', onMouseUp);
    };

    return {
        width,
        startResize
    };
}
