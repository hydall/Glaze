import { imageViewerMode } from './APPSettings.js';
import { openHolocardsViewer } from './holocardsViewer.js';

export function openImageViewer(src, nameOrCallback, description = "", onCloseCallback) {
    let name = "Character";
    let cb = null;

    if (typeof nameOrCallback === 'function') {
        cb = nameOrCallback;
    } else if (typeof nameOrCallback === 'string') {
        name = nameOrCallback;
        cb = onCloseCallback;
    }

    if (imageViewerMode === 'holo' || imageViewerMode === 'holocards') {
        return openHolocardsViewer(src, name, description, cb);
    }

    let overlay = document.getElementById('image-viewer-overlay');
    let img;

    if (!overlay) {
        overlay = document.createElement('div');
        overlay.id = 'image-viewer-overlay';
        overlay.className = 'image-viewer-overlay';
        overlay.style.zIndex = '20000'; // Ensure it's on top of everything
        overlay.innerHTML = `
            <div class="image-viewer-container" style="width:100%;height:100%;display:flex;align-items:center;justify-content:center;overflow:hidden;touch-action:none;">
                <img class="image-viewer-img" src="" alt="Full view" style="transform-origin: center; transition: transform 0.1s ease-out;">
            </div>
            <div id="image-viewer-close-btn" style="position: absolute; top: calc(10px + env(safe-area-inset-top)); right: 10px; z-index: 20020; padding: 10px; cursor: pointer; display: flex; align-items: center; justify-content: center;">
                <svg viewBox="0 0 24 24" style="width:32px;height:32px;fill:white;filter:drop-shadow(0 1px 3px rgba(0,0,0,0.5));"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
            </div>
        `;
        document.body.appendChild(overlay);
        
        img = overlay.querySelector('.image-viewer-img');
        const container = overlay.querySelector('.image-viewer-container');
        const closeBtn = overlay.querySelector('#image-viewer-close-btn');

        // Zoom State
        let scale = 1;
        let pointX = 0;
        let pointY = 0;
        let startX = 0;
        let startY = 0;
        let isDragging = false;
        let startDist = 0;
        let startScale = 1;
        let startPinchX = 0;
        let startPinchY = 0;
        let startPointX = 0;
        let startPointY = 0;

        const updateTransform = () => {
            img.style.transform = `translate(${pointX}px, ${pointY}px) scale(${scale})`;
        };

        const resetZoom = () => {
            scale = 1;
            pointX = 0;
            pointY = 0;
            img.style.transition = 'transform 0.3s ease';
            updateTransform();
            setTimeout(() => { img.style.transition = 'transform 0.1s ease-out'; }, 300);
        };

        overlay.closeViewer = () => {
            overlay.classList.remove('visible');
            setTimeout(() => { 
                overlay.style.display = 'none'; 
                resetZoom();
                if (overlay._onCloseCallback) overlay._onCloseCallback();
            }, 300);
        };
        
        closeBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            overlay.closeViewer();
        });
        
        // Close on background click (if not interacting)
        let isInteracting = false;
        overlay.addEventListener('click', (e) => {
            if (isInteracting) { isInteracting = false; return; }
            if (scale > 1.1) return; // Don't close if zoomed in
            overlay.closeViewer();
        });

        // Touch Logic
        container.addEventListener('touchstart', (e) => {
            if (e.touches.length === 2) {
                isDragging = false;
                startDist = Math.hypot(
                    e.touches[0].clientX - e.touches[1].clientX,
                    e.touches[0].clientY - e.touches[1].clientY
                );
                startScale = scale;
                startPointX = pointX;
                startPointY = pointY;

                // Calculate center of pinch relative to container center
                const rect = container.getBoundingClientRect();
                const cx = (e.touches[0].clientX + e.touches[1].clientX) / 2;
                const cy = (e.touches[0].clientY + e.touches[1].clientY) / 2;
                startPinchX = cx - rect.left - rect.width / 2;
                startPinchY = cy - rect.top - rect.height / 2;
            } else if (e.touches.length === 1) {
                isDragging = true;
                startX = e.touches[0].clientX - pointX;
                startY = e.touches[0].clientY - pointY;
            }
        });

        container.addEventListener('touchmove', (e) => {
            e.preventDefault();
            isInteracting = true;

            if (e.touches.length === 2) {
                const dist = Math.hypot(
                    e.touches[0].clientX - e.touches[1].clientX,
                    e.touches[0].clientY - e.touches[1].clientY
                );
                if (startDist > 0) {
                    const newScale = Math.max(1, Math.min(startScale * (dist / startDist), 5));
                    
                    // Calculate current pinch center
                    const rect = container.getBoundingClientRect();
                    const cx = (e.touches[0].clientX + e.touches[1].clientX) / 2;
                    const cy = (e.touches[0].clientY + e.touches[1].clientY) / 2;
                    const currentPinchX = cx - rect.left - rect.width / 2;
                    const currentPinchY = cy - rect.top - rect.height / 2;

                    // Math to keep the focal point under the fingers
                    // T2 = P2 - (P1 - T1) * (S2 / S1)
                    const scaleRatio = newScale / startScale;
                    pointX = currentPinchX - (startPinchX - startPointX) * scaleRatio;
                    pointY = currentPinchY - (startPinchY - startPointY) * scaleRatio;
                    scale = newScale;
                    
                    updateTransform();
                }
            } else if (e.touches.length === 1 && isDragging && scale > 1) {
                pointX = e.touches[0].clientX - startX;
                pointY = e.touches[0].clientY - startY;
                updateTransform();
            }
        });

        container.addEventListener('touchend', (e) => {
            isDragging = false;
            if (e.touches.length < 2) startDist = 0;
            // Smoothly switch to panning if one finger remains
            if (e.touches.length === 1) {
                isDragging = true;
                startX = e.touches[0].clientX - pointX;
                startY = e.touches[0].clientY - pointY;
            }
            if (scale < 1) resetZoom();
        });

        // Double tap
        let lastTap = 0;
        container.addEventListener('click', (e) => {
            const cur = new Date().getTime();
            const tapLen = cur - lastTap;
            if (tapLen < 300 && tapLen > 0) {
                e.preventDefault();
                e.stopPropagation();
                if (scale > 1) resetZoom();
                else {
                    scale = 2.5;
                    // Zoom towards tap position
                    const rect = container.getBoundingClientRect();
                    const tapX = e.clientX - rect.left - rect.width / 2;
                    const tapY = e.clientY - rect.top - rect.height / 2;
                    pointX = -1.5 * tapX; // (P - (P - 0) * 2.5) = P - 2.5P = -1.5P
                    pointY = -1.5 * tapY;
                    
                    img.style.transition = 'transform 0.3s ease';
                    updateTransform();
                    setTimeout(() => { img.style.transition = 'transform 0.1s ease-out'; }, 300);
                }
            }
            lastTap = cur;
        });
    } else {
        img = overlay.querySelector('.image-viewer-img');
    }
    
    overlay._onCloseCallback = cb;
    
    img.src = src;
    overlay.style.display = 'flex';
    requestAnimationFrame(() => {
        overlay.classList.add('visible');
    });
}