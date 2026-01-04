let genericSheetOverlay = null;
let activeSheetConfig = null;
let closeTimer = null;

export function initGenericBottomSheet() {
    if (document.getElementById('generic-bottom-sheet')) {
        genericSheetOverlay = document.getElementById('generic-bottom-sheet');
        return;
    }

    const overlay = document.createElement('div');
    overlay.id = 'generic-bottom-sheet';
    overlay.className = 'modal-overlay bottom-sheet-overlay';
    overlay.style.display = 'none';
    overlay.innerHTML = `
        <div class="bottom-sheet-content">
            <div class="sheet-handle-bar"></div>
            <div class="sheet-header" style="display:none;">
                <span class="sheet-title"></span>
                <div class="sheet-header-action"></div>
            </div>
            <div class="sheet-scroll-container" style="overflow-y: auto; max-height: 70vh;">
                <div class="sheet-list"></div>
                <div class="sheet-custom-content"></div>
            </div>
        </div>
    `;
    document.body.appendChild(overlay);
    genericSheetOverlay = overlay;

    const content = overlay.querySelector('.bottom-sheet-content');
    let startY = 0;
    let isDragging = false;

    overlay.addEventListener('click', (e) => {
        if (e.target === overlay) closeBottomSheet();
    });

    content.addEventListener('touchstart', (e) => {
        const scrollContainer = overlay.querySelector('.sheet-scroll-container');
        if (scrollContainer && scrollContainer.scrollTop > 0) return;
        
        startY = e.touches[0].clientY;
        isDragging = true;
        content.style.transition = 'none';
    }, { passive: true });

    content.addEventListener('touchmove', (e) => {
        if (!isDragging) return; 
        const delta = e.touches[0].clientY - startY;
        if (delta > 0) {
            e.preventDefault();
            content.style.transform = `translateY(${delta}px)`;
        }
    }, { passive: false });

    content.addEventListener('touchend', (e) => {
        if (!isDragging) return;
        isDragging = false;
        const delta = e.changedTouches[0].clientY - startY;
        content.style.transition = '';
        if (delta > 100) {
            closeBottomSheet();
        } else {
            content.style.transform = '';
        }
    });
}

export function showBottomSheet({ title, items, content, headerAction, onClose }) {
    if (!genericSheetOverlay) initGenericBottomSheet();
    const overlay = genericSheetOverlay;
    
    if (closeTimer) {
        clearTimeout(closeTimer);
        closeTimer = null;
    }

    const titleEl = overlay.querySelector('.sheet-title');
    const headerEl = overlay.querySelector('.sheet-header');
    const headerActionEl = overlay.querySelector('.sheet-header-action');
    const listEl = overlay.querySelector('.sheet-list');
    const customEl = overlay.querySelector('.sheet-custom-content');

    // Reset
    listEl.innerHTML = '';
    customEl.innerHTML = '';
    headerActionEl.innerHTML = '';
    listEl.style.display = 'none';
    customEl.style.display = 'none';

    // Title
    if (title) {
        titleEl.textContent = title;
        headerEl.style.display = 'flex';
    } else {
        headerEl.style.display = 'none';
    }

    // Header Action
    if (headerAction) {
        const btn = document.createElement('div');
        btn.className = 'sheet-action-btn';
        btn.innerHTML = headerAction.icon || '+';
        btn.onclick = (e) => {
            e.stopPropagation();
            if (headerAction.onClick) headerAction.onClick();
        };
        headerActionEl.appendChild(btn);
    }

    // Items List
    if (items && items.length > 0) {
        items.forEach(item => {
            const el = document.createElement('div');
            el.className = 'sheet-item';
            if (item.id) el.id = item.id;
            
            const iconHtml = item.icon ? `<div class="sheet-item-icon" style="${item.iconColor ? 'fill:'+item.iconColor : ''}">${item.icon}</div>` : '';
            const labelStyle = item.isDestructive ? 'color: #ff4444;' : '';
            const descHtml = item.description ? `<div style="font-size: 12px; opacity: 0.7; margin-top: 2px;">${item.description}</div>` : '';
            
            el.innerHTML = `
                ${iconHtml}
                <div class="sheet-item-content" style="${labelStyle}"><div>${item.label}</div>${descHtml}</div>
            `;
            
            el.onclick = (e) => {
                if (item.onClick) item.onClick(e);
            };
            listEl.appendChild(el);
        });
        listEl.style.display = 'block';
    }

    // Custom Content
    if (content) {
        if (typeof content === 'string') {
            customEl.innerHTML = content;
        } else if (content instanceof HTMLElement || content instanceof DocumentFragment) {
            customEl.appendChild(content);
        }
        customEl.style.display = 'block';
    }

    activeSheetConfig = { onClose };

    overlay.style.display = 'flex';
    const contentEl = overlay.querySelector('.bottom-sheet-content');
    
    // Double RAF ensures the browser paints the display:flex frame before adding the class
    requestAnimationFrame(() => {
        requestAnimationFrame(() => {
            contentEl.style.transform = ''; 
            overlay.classList.add('visible');
        });
    });
}

export function showBigInfoSheet({ title, icon, description, buttonText, onButtonClick }) {
    const content = document.createElement('div');
    content.style.cssText = "display: flex; flex-direction: column; align-items: center; padding: 20px 20px 10px; text-align: center;";
    
    const iconDiv = document.createElement('div');
    iconDiv.style.cssText = "width: 64px; height: 64px; margin-bottom: 16px; color: var(--text-gray); opacity: 0.5;";
    iconDiv.innerHTML = icon || '';
    
    const descDiv = document.createElement('div');
    descDiv.style.cssText = "font-size: 16px; color: var(--text-black); margin-bottom: 24px; line-height: 1.5;";
    descDiv.textContent = description || '';
    
    const btn = document.createElement('div');
    btn.className = 'btn-save';
    btn.style.cssText = "width: 100%; padding: 12px; background-color: var(--vk-blue); color: white; border-radius: 8px; font-weight: 500; cursor: pointer; text-align: center;";
    btn.textContent = buttonText || 'OK';
    btn.onclick = () => {
        if (onButtonClick) onButtonClick();
    };
    
    content.appendChild(iconDiv);
    content.appendChild(descDiv);
    content.appendChild(btn);
    
    showBottomSheet({ title, content });
}

export function closeBottomSheet() {
    if (!genericSheetOverlay) return;
    const overlay = genericSheetOverlay;
    const content = overlay.querySelector('.bottom-sheet-content');
    
    content.style.transform = '';
    overlay.classList.remove('visible');
    
    if (activeSheetConfig && activeSheetConfig.onClose) {
        activeSheetConfig.onClose();
    }
    activeSheetConfig = null;

    if (closeTimer) clearTimeout(closeTimer);
    closeTimer = setTimeout(() => {
        overlay.style.display = 'none';
        content.style.transform = '';
        closeTimer = null;
    }, 300);
}