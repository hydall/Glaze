import { ref, computed, watch, nextTick, onBeforeUnmount, unref } from 'vue';
import { shouldUseBatterySaverUI } from '@/core/config/APPSettings.js';
import { createHeightCache } from '@/composables/chat/virtualScrollHeightCache.js';
import { useVirtualScrollNavigation } from '@/composables/chat/useVirtualScrollNavigation.js';

export function useVirtualScroll(itemsRef, containerRef, options = {}) {
    const getBuffer = () => unref(options.buffer) ?? 10;
    const estimateHeight = options.estimateHeight ?? 80;

    const renderStart = ref(0);
    const renderEnd = ref(20);
    const paddingTop = ref(0);
    const paddingBottom = ref(0);
    const columns = ref(1);
    const isScrolling = ref(false);
    const isProgrammaticScrolling = ref(false);
    let scrollTimeout = null;
    let scrollRaf = null;
    const pendingTimeouts = new Set();
    let mounted = true;

    const visibleIndices = new Set();
    const realVisibleIndices = new Set();

    let observer = null;
    let realObserver = null;
    let gridResizeObserver = null;

    const cache = createHeightCache({
        getItemLength: () => itemsRef.value?.length || 0,
        getColumns: () => columns.value,
        estimateHeight
    });

    function trackTimeout(fn, delay) {
        const id = setTimeout(() => {
            pendingTimeouts.delete(id);
            if (mounted) fn();
        }, delay);
        pendingTimeouts.add(id);
        return id;
    }

    function clearAllPendingTimeouts() {
        for (const id of pendingTimeouts) clearTimeout(id);
        pendingTimeouts.clear();
        if (scrollTimeout) { clearTimeout(scrollTimeout); scrollTimeout = null; }
    }

    const visibleItems = computed(() => {
        const items = itemsRef.value || [];
        const start = Math.max(0, renderStart.value);
        const end = Math.min(items.length, renderEnd.value);
        const slice = [];
        for (let i = start; i < end; i++) {
            slice.push({
                item: items[i],
                index: i,
                key: `${items[i].id || items[i].timestamp || ''}_${i}`
            });
        }
        return slice;
    });

    const updateSpacers = () => {
        const { top, bottom } = cache.computeSpacers(renderStart.value, renderEnd.value);
        paddingTop.value = top;
        paddingBottom.value = bottom;
    };

    const updateWindow = () => {
        if (visibleIndices.size === 0) return;

        const indices = Array.from(visibleIndices).sort((a, b) => a - b);
        const minVis = indices[0];
        const maxVis = indices[indices.length - 1];
        const total = itemsRef.value?.length || 0;

        const buffer = getBuffer();
        const cols = columns.value;
        let newStart = Math.max(0, minVis - buffer);
        let newEnd = Math.min(total, maxVis + buffer + 1);

        if (cols > 1) {
            newStart = Math.floor(newStart / cols) * cols;
            newEnd = Math.ceil(newEnd / cols) * cols;
            newEnd = Math.min(total, newEnd);
        }

        if (newStart !== renderStart.value || newEnd !== renderEnd.value) {
            renderStart.value = newStart;
            renderEnd.value = newEnd;
            updateSpacers();
        }
    };

    const observeItems = () => {
        if (!containerRef.value) return;
        if (observer) observer.disconnect();
        if (realObserver) realObserver.disconnect();
        const children = containerRef.value.querySelectorAll('[data-index]');
        if (!observer || !realObserver) return;
        children.forEach(el => { observer.observe(el); realObserver.observe(el); });
    };

    const onContainerScroll = () => {
        if (!containerRef.value || isProgrammaticScrolling.value) return;

        if (!isScrolling.value) isScrolling.value = true;
        clearTimeout(scrollTimeout);
        scrollTimeout = setTimeout(() => { if (mounted) isScrolling.value = false; }, 150);

        const runScrollWork = () => {
            scrollRaf = null;
            if (!mounted || !containerRef.value) return;

            const scrollTop = containerRef.value.scrollTop;
            const clientHeight = containerRef.value.clientHeight;
            const renderedTop = paddingTop.value;
            const renderedContentHeight = cache.getRenderedContentHeight(renderStart.value, renderEnd.value);
            const renderedBottom = renderedTop + renderedContentHeight;
            const scrollBuffer = 2000;

            if (scrollTop < renderedTop - scrollBuffer || scrollTop + clientHeight > renderedBottom + scrollBuffer) {
                const count = itemsRef.value.length;
                const cols = columns.value;
                const targetRow = cache.findRowAtScrollTop(scrollTop);
                const targetIndex = targetRow >= 0 ? targetRow * cols : Math.max(0, count - 1);

                const buffer = getBuffer();
                let newStart = Math.max(0, targetIndex - buffer);

                const sums = cache.ensure();
                let hSum = 0;
                let r = Math.floor(targetIndex / cols);
                while (hSum < clientHeight + 1000 && r * cols < count) {
                    hSum += sums[r + 1] - sums[r];
                    r++;
                }
                let newEnd = Math.min(count, r * cols + buffer);

                if (cols > 1) {
                    newStart = Math.floor(newStart / cols) * cols;
                    newEnd = Math.ceil(newEnd / cols) * cols;
                    newEnd = Math.min(count, newEnd);
                }

                if (newStart !== renderStart.value || newEnd !== renderEnd.value) {
                    renderStart.value = newStart;
                    renderEnd.value = newEnd;
                    visibleIndices.clear();
                    realVisibleIndices.clear();
                    updateSpacers();
                    nextTick(observeItems);
                }
            } else if (!shouldUseBatterySaverUI()) {
                const children = containerRef.value.querySelectorAll('[data-index]');
                const containerRect = containerRef.value.getBoundingClientRect();
                const style = window.getComputedStyle(containerRef.value);
                const paddingBottomVal = parseFloat(style.paddingBottom) || 0;
                const visibleBottom = containerRect.bottom - paddingBottomVal;
                const visibleTop = containerRect.top;

                children.forEach(el => {
                    const index = parseInt(el.dataset.index);
                    if (isNaN(index)) return;
                    const rect = el.getBoundingClientRect();
                    if (rect.top < visibleBottom - 20 && rect.bottom > visibleTop + 20) {
                        realVisibleIndices.add(index);
                    } else {
                        realVisibleIndices.delete(index);
                    }
                });
            }
        };

        if (shouldUseBatterySaverUI()) {
            if (scrollRaf) return;
            scrollRaf = requestAnimationFrame(runScrollWork);
            return;
        }
        runScrollWork();
    };

    const initObservers = () => {
        if (observer) observer.disconnect();

        observer = new IntersectionObserver((entries) => {
            if (!mounted) return;
            let changed = false;
            entries.forEach(entry => {
                const index = parseInt(entry.target.dataset.index);
                if (isNaN(index)) return;
                if (entry.boundingClientRect.height > 0) {
                    cache.setHeight(index, entry.boundingClientRect.height);
                }
                if (entry.isIntersecting) { visibleIndices.add(index); changed = true; }
                else { visibleIndices.delete(index); changed = true; }
            });
            if (changed) updateWindow();
        }, { root: containerRef.value, threshold: 0.01, rootMargin: '1000px' });

        realObserver = new IntersectionObserver((entries) => {
            if (!mounted) return;
            entries.forEach(entry => {
                const index = parseInt(entry.target.dataset.index);
                if (isNaN(index)) return;
                if (entry.isIntersecting) {
                    const container = containerRef.value;
                    if (container) {
                        const containerRect = container.getBoundingClientRect();
                        const entryRect = entry.boundingClientRect;
                        const style = window.getComputedStyle(container);
                        const paddingBottomVal = parseFloat(style.paddingBottom) || 0;
                        const visibleBottom = containerRect.bottom - paddingBottomVal;
                        if (entryRect.top >= visibleBottom - 20) {
                            realVisibleIndices.delete(index);
                            return;
                        }
                    }
                    realVisibleIndices.add(index);
                } else {
                    realVisibleIndices.delete(index);
                }
            });
        }, { root: containerRef.value, threshold: [0, 0.1, 0.5, 1.0] });

        nextTick(observeItems);

        if (options.grid) {
            updateColumns();
            gridResizeObserver = new ResizeObserver(() => updateColumns());
            gridResizeObserver.observe(containerRef.value);
        }
    };

    const updateColumns = () => {
        if (!options.grid || !containerRef.value) return;
        const style = window.getComputedStyle(containerRef.value);
        const gridCols = style.gridTemplateColumns;
        if (gridCols && gridCols !== 'none') {
            const numCols = gridCols.split(' ').length;
            if (columns.value !== numCols) {
                columns.value = numCols > 0 ? numCols : 1;
                cache.invalidate();
                updateWindow();
                updateSpacers();
            }
        }
    };

    const {
        getScrollAnchor,
        scrollToAnchor,
        scrollToBottom,
        scrollToIndex
    } = useVirtualScrollNavigation({
        itemsRef,
        containerRef,
        renderStart,
        renderEnd,
        paddingTop,
        columns,
        visibleIndices,
        realVisibleIndices,
        cache,
        observeItems,
        updateSpacers,
        isProgrammaticScrolling,
        mounted,
        trackTimeout,
        getBuffer,
        estimateHeight
    });

    watch(itemsRef, (newItems, oldItems) => {
        const newLen = newItems ? newItems.length : 0;
        const oldLen = oldItems ? oldItems.length : 0;

        cache.invalidate();
        cache.pruneStale();

        if (newLen > oldLen) {
            const wasAtBottom = containerRef.value && (containerRef.value.scrollHeight - containerRef.value.scrollTop - containerRef.value.clientHeight < 100);
            if (wasAtBottom) {
                renderEnd.value = newLen;
                const viewportHeight = containerRef.value?.clientHeight || 800;
                const estimatedItemsInView = Math.max(20, Math.ceil(viewportHeight / estimateHeight) + getBuffer());
                renderStart.value = Math.max(0, newLen - estimatedItemsInView);
                trackTimeout(() => { if (mounted) scrollToBottom('auto'); }, 50);
            } else {
                if (newLen > renderEnd.value) renderEnd.value = newLen;
            }
        }
        updateSpacers();
        nextTick(observeItems);
    });

    watch(visibleItems, () => { nextTick(observeItems); });

    const refresh = () => {
        cache.clear();
        visibleIndices.clear();
        realVisibleIndices.clear();
        const count = itemsRef.value?.length || 0;
        const viewportHeight = containerRef.value?.clientHeight || 800;
        const estimatedItemsInView = Math.max(20, Math.ceil(viewportHeight / estimateHeight) + getBuffer());
        renderStart.value = Math.max(0, count - estimatedItemsInView);
        renderEnd.value = count;
        updateSpacers();
        nextTick(() => {
            if (!mounted) return;
            initObservers();
            trackTimeout(updateSpacers, 100);
        });
    };

    watch(containerRef, (el, oldEl) => {
        if (oldEl) oldEl.removeEventListener('scroll', onContainerScroll);
        if (el) {
            initObservers();
            el.addEventListener('scroll', onContainerScroll, { passive: true });
        }
    });

    onBeforeUnmount(() => {
        mounted = false;
        clearAllPendingTimeouts();
        if (observer) observer.disconnect();
        if (realObserver) realObserver.disconnect();
        if (gridResizeObserver) gridResizeObserver.disconnect();
        if (containerRef.value) containerRef.value.removeEventListener('scroll', onContainerScroll);
        if (scrollRaf) { cancelAnimationFrame(scrollRaf); scrollRaf = null; }
        cache.clear();
        visibleIndices.clear();
        realVisibleIndices.clear();
    });

    const isItemVisible = (index) => realVisibleIndices.has(index);

    return {
        visibleItems,
        paddingTop,
        paddingBottom,
        refresh,
        scrollToBottom,
        isScrolling,
        isProgrammaticScrolling,
        getScrollAnchor,
        scrollToAnchor,
        scrollToIndex,
        isItemVisible
    };
}
