import { ref, computed, watch, nextTick, onBeforeUnmount, unref } from 'vue';
import { Capacitor } from '@capacitor/core';
import { shouldUseBatterySaverUI } from '@/core/config/APPSettings.js';

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
    let programmaticSeq = 0;
    const pendingTimeouts = new Set();

    const itemHeights = new Map();
    let prefixSumCache = null;
    let prefixSumDirty = true;

    const visibleIndices = new Set();
    const realVisibleIndices = new Set();

    let observer = null;
    let realObserver = null;
    let gridResizeObserver = null;
    let mounted = true;

    function trackTimeout(fn, delay) {
        const id = setTimeout(() => {
            pendingTimeouts.delete(id);
            if (mounted) fn();
        }, delay);
        pendingTimeouts.add(id);
        return id;
    }

    function clearAllPendingTimeouts() {
        for (const id of pendingTimeouts) {
            clearTimeout(id);
        }
        pendingTimeouts.clear();
        if (scrollTimeout) {
            clearTimeout(scrollTimeout);
            scrollTimeout = null;
        }
    }

    function invalidatePrefixSum() {
        prefixSumDirty = true;
    }

    function ensurePrefixSum() {
        if (!prefixSumDirty && prefixSumCache) return prefixSumCache;

        const items = itemsRef.value || [];
        const cols = columns.value;
        const count = items.length;
        const sums = [0];

        for (let i = 0; i < count; i += cols) {
            let rowHeight = 0;
            for (let j = 0; j < cols && i + j < count; j++) {
                const h = itemHeights.get(i + j) || estimateHeight;
                if (h > rowHeight) rowHeight = h;
            }
            sums.push(sums[sums.length - 1] + rowHeight);
        }

        prefixSumCache = sums;
        prefixSumDirty = false;
        return sums;
    }

    function getHeightUpTo(index) {
        const sums = ensurePrefixSum();
        const cols = columns.value;
        const rowIdx = Math.floor(index / cols);
        return rowIdx < sums.length ? sums[rowIdx] : sums[sums.length - 1];
    }

    function getTotalHeight() {
        const sums = ensurePrefixSum();
        return sums[sums.length - 1];
    }

    function pruneStaleHeights() {
        const count = itemsRef.value?.length || 0;
        for (const key of itemHeights.keys()) {
            if (key >= count) itemHeights.delete(key);
        }
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
        pruneStaleHeights();
        const sums = ensurePrefixSum();
        const start = renderStart.value;
        const end = renderEnd.value;
        const cols = columns.value;
        const total = itemsRef.value?.length || 0;

        const startRow = Math.floor(start / cols);
        paddingTop.value = startRow < sums.length ? sums[startRow] : 0;

        let bottom = 0;
        let rowStart = end;
        if (cols > 1) {
            rowStart = Math.ceil(end / cols) * cols;
        }
        const endRow = Math.floor(rowStart / cols);
        const totalRows = sums.length - 1;
        if (endRow < totalRows) {
            bottom = sums[totalRows] - sums[Math.min(endRow, totalRows)];
        }
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
        children.forEach(el => {
            observer.observe(el);
            realObserver.observe(el);
        });
    };

    const onContainerScroll = () => {
        if (!containerRef.value || isProgrammaticScrolling.value) return;

        if (!isScrolling.value) isScrolling.value = true;
        clearTimeout(scrollTimeout);
        scrollTimeout = setTimeout(() => {
            if (mounted) isScrolling.value = false;
        }, 150);

        const runScrollWork = () => {
            scrollRaf = null;
            if (!mounted || !containerRef.value) return;

            const scrollTop = containerRef.value.scrollTop;
            const clientHeight = containerRef.value.clientHeight;

            const renderedTop = paddingTop.value;

            const sums = ensurePrefixSum();
            const start = renderStart.value;
            const end = renderEnd.value;
            const cols = columns.value;
            const startRow = Math.floor(start / cols);
            const endRow = Math.floor(end / cols);
            const renderedContentHeight = (endRow < sums.length ? sums[endRow] : sums[sums.length - 1]) - (startRow < sums.length ? sums[startRow] : 0);
            const renderedBottom = renderedTop + renderedContentHeight;

            const scrollBuffer = 2000;

            if (scrollTop < renderedTop - scrollBuffer || scrollTop + clientHeight > renderedBottom + scrollBuffer) {
                const count = itemsRef.value.length;
                let targetRow = -1;
                for (let r = 0; r < sums.length - 1; r++) {
                    if (sums[r + 1] > scrollTop) {
                        targetRow = r;
                        break;
                    }
                }

                let targetIndex = targetRow >= 0 ? targetRow * cols : Math.max(0, count - 1);

                const buffer = getBuffer();
                let newStart = Math.max(0, targetIndex - buffer);

                let hSum = 0;
                let r = Math.floor(targetIndex / cols);
                while (hSum < clientHeight + 1000 && r * cols < count) {
                    const rowH = sums[r + 1] - sums[r];
                    hSum += rowH;
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

    const getScrollAnchor = () => {
        if (!containerRef.value) return null;

        const children = containerRef.value.querySelectorAll('[data-index]');
        if (!children || children.length === 0) {
            return { index: (itemsRef.value?.length || 0) - 1, offset: 0 };
        }

        const containerTop = containerRef.value.getBoundingClientRect().top;

        for (const child of children) {
            const rect = child.getBoundingClientRect();
            if (rect.bottom > containerTop) {
                const index = parseInt(child.dataset.index);
                if (!isNaN(index)) {
                    return { index, offset: containerTop - rect.top };
                }
            }
        }
        return { index: (itemsRef.value?.length || 0) - 1, offset: 0 };
    };

    function beginProgrammaticScroll() {
        programmaticSeq += 1;
        isProgrammaticScrolling.value = true;
        return programmaticSeq;
    }

    function endProgrammaticScroll(seq, delay = 50) {
        trackTimeout(() => {
            if (programmaticSeq === seq) {
                isProgrammaticScrolling.value = false;
            }
        }, delay);
    }

    const scrollToAnchor = (anchor) => {
        return new Promise((resolve) => {
            if (!anchor || typeof anchor.index !== 'number') {
                resolve();
                return;
            }
            const count = itemsRef.value.length;
            if (count === 0) {
                resolve();
                return;
            }

            const index = Math.max(0, Math.min(anchor.index, count - 1));
            const seq = beginProgrammaticScroll();

            const buffer = getBuffer();
            const cols = columns.value;
            let newStart = Math.max(0, index - buffer);
            let newEnd = Math.min(count, index + buffer + 1);

            if (cols > 1) {
                newStart = Math.floor(newStart / cols) * cols;
                newEnd = Math.ceil(newEnd / cols) * cols;
                newEnd = Math.min(count, newEnd);
            }

            renderStart.value = newStart;
            renderEnd.value = newEnd;

            visibleIndices.clear();
            updateSpacers();

            nextTick(() => {
                if (!mounted || !containerRef.value) {
                    resolve();
                    return;
                }
                const currentCount = itemsRef.value.length;
                if (currentCount !== count) {
                    endProgrammaticScroll(seq);
                    resolve();
                    return;
                }

                const children = containerRef.value.querySelectorAll('[data-index]');
                children.forEach(el => {
                    const idx = parseInt(el.dataset.index);
                    if (!isNaN(idx)) {
                        const h = el.getBoundingClientRect().height;
                        if (h > 0) itemHeights.set(idx, h);
                    }
                });
                invalidatePrefixSum();

                let targetTop = paddingTop.value;
                const alignedIndex = Math.floor(index / cols) * cols;

                for (let i = renderStart.value; i < alignedIndex; i += cols) {
                    let rowHeight = 0;
                    for (let j = 0; j < cols && i + j < alignedIndex; j++) {
                        const h = itemHeights.get(i + j) || estimateHeight;
                        if (h > rowHeight) rowHeight = h;
                    }
                    targetTop += rowHeight;
                }
                targetTop += (anchor.offset || 0);

                const style = window.getComputedStyle(containerRef.value);
                const containerPaddingTop = parseFloat(style.paddingTop) || 0;
                targetTop += containerPaddingTop;

                containerRef.value.scrollTop = targetTop;
                observeItems();
                endProgrammaticScroll(seq);
                resolve();
            });
        });
    };

    const scrollToBottom = (behavior = 'auto') => {
        const count = itemsRef.value.length;
        if (count === 0) return;

        let effectiveBehavior = behavior;

        if (containerRef.value) {
            const { scrollTop, scrollHeight, clientHeight } = containerRef.value;
            if (scrollHeight - scrollTop - clientHeight > 3000) {
                effectiveBehavior = 'auto';
            }
        }

        const viewportHeight = containerRef.value?.clientHeight || 800;
        const estimatedItemsInView = Math.max(20, Math.ceil(viewportHeight / estimateHeight) + getBuffer());

        renderStart.value = Math.max(0, count - estimatedItemsInView);
        renderEnd.value = count;
        visibleIndices.clear();
        updateSpacers();

        const seq = beginProgrammaticScroll();

        nextTick(() => {
            nextTick(() => {
                requestAnimationFrame(() => {
                    if (!mounted || !containerRef.value) return;
                    const doScroll = () => {
                        if (!mounted || !containerRef.value) return;
                        containerRef.value.scrollTop = containerRef.value.scrollHeight;
                        observeItems();
                    };

                    if (effectiveBehavior === 'smooth') {
                        containerRef.value.scrollTo({ top: containerRef.value.scrollHeight, behavior: 'smooth' });
                        observeItems();
                        endProgrammaticScroll(seq, 500);
                    } else {
                        doScroll();
                        endProgrammaticScroll(seq, 150);
                        trackTimeout(doScroll, 50);
                    }
                });
            });
        });
    };

    const initObservers = () => {
        if (observer) observer.disconnect();

        observer = new IntersectionObserver((entries) => {
            if (!mounted) return;
            let changed = false;
            entries.forEach(entry => {
                const index = parseInt(entry.target.dataset.index);
                if (isNaN(index)) return;

                const rect = entry.boundingClientRect;
                if (rect.height > 0) {
                    const prev = itemHeights.get(index);
                    if (prev !== rect.height) {
                        itemHeights.set(index, rect.height);
                        invalidatePrefixSum();
                    }
                }

                if (entry.isIntersecting) {
                    visibleIndices.add(index);
                    changed = true;
                } else {
                    visibleIndices.delete(index);
                    changed = true;
                }
            });

            if (changed) {
                updateWindow();
            }
        }, {
            root: containerRef.value,
            threshold: 0.01,
            rootMargin: '1000px'
        });

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
        }, {
            root: containerRef.value,
            threshold: [0, 0.1, 0.5, 1.0]
        });

        nextTick(() => {
            observeItems();
        });

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
                invalidatePrefixSum();
                updateWindow();
                updateSpacers();
            }
        }
    };

    watch(itemsRef, (newItems, oldItems) => {
        const newLen = newItems ? newItems.length : 0;
        const oldLen = oldItems ? oldItems.length : 0;

        invalidatePrefixSum();
        pruneStaleHeights();

        if (newLen > oldLen) {
            const wasAtBottom = containerRef.value && (containerRef.value.scrollHeight - containerRef.value.scrollTop - containerRef.value.clientHeight < 100);
            if (wasAtBottom) {
                renderEnd.value = newLen;
                const viewportHeight = containerRef.value?.clientHeight || 800;
                const estimatedItemsInView = Math.max(20, Math.ceil(viewportHeight / estimateHeight) + getBuffer());
                renderStart.value = Math.max(0, newLen - estimatedItemsInView);
                trackTimeout(() => {
                    if (mounted) scrollToBottom('auto');
                }, 50);
            } else {
                if (newLen > renderEnd.value) {
                    renderEnd.value = newLen;
                }
            }
        }
        updateSpacers();
        nextTick(observeItems);
    });

    watch(visibleItems, () => {
        nextTick(observeItems);
    });

    const refresh = () => {
        itemHeights.clear();
        invalidatePrefixSum();
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
        if (oldEl) {
            oldEl.removeEventListener('scroll', onContainerScroll);
        }
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
        if (containerRef.value) {
            containerRef.value.removeEventListener('scroll', onContainerScroll);
        }
        if (scrollRaf) {
            cancelAnimationFrame(scrollRaf);
            scrollRaf = null;
        }
        itemHeights.clear();
        visibleIndices.clear();
        realVisibleIndices.clear();
    });

    const scrollToIndex = (index, behavior = 'auto', align = 'center') => {
        return new Promise((resolve) => {
            if (typeof index !== 'number') {
                resolve();
                return;
            }
            const count = itemsRef.value.length;
            if (count === 0) {
                resolve();
                return;
            }

            index = Math.max(0, Math.min(index, count - 1));
            const seq = beginProgrammaticScroll();

            if (index >= renderStart.value && index < renderEnd.value && containerRef.value) {
                nextTick(() => {
                    if (!mounted || !containerRef.value) {
                        endProgrammaticScroll(seq);
                        resolve();
                        return;
                    }
                    const el = containerRef.value.querySelector(`[data-index="${index}"]`);
                    if (el) {
                        const containerRect = containerRef.value.getBoundingClientRect();
                        const elRect = el.getBoundingClientRect();
                        let targetTop = containerRef.value.scrollTop + (elRect.top - containerRect.top);

                        if (align === 'center') {
                            const style = window.getComputedStyle(containerRef.value);
                            const containerPaddingTop = parseFloat(style.paddingTop) || 0;
                            const containerPaddingBottom = parseFloat(style.paddingBottom) || 0;
                            const visibleHeight = containerRect.height - containerPaddingTop - containerPaddingBottom;
                            targetTop = targetTop - containerPaddingTop - (visibleHeight / 2) + (elRect.height / 2);
                        } else if (align === 'top') {
                            const style = window.getComputedStyle(containerRef.value);
                            const containerPaddingTop = parseFloat(style.paddingTop) || 0;
                            targetTop = targetTop - containerPaddingTop;
                            targetTop -= 10;
                        }

                        containerRef.value.scrollTo({ top: Math.max(0, targetTop), behavior });
                    }
                    endProgrammaticScroll(seq, behavior === 'smooth' ? 300 : 50);
                    resolve();
                });
                return;
            }

            const buffer = getBuffer();
            const cols = columns.value;
            let newStart = Math.max(0, index - buffer);
            let newEnd = Math.min(count, index + buffer + 1);

            if (cols > 1) {
                newStart = Math.floor(newStart / cols) * cols;
                newEnd = Math.ceil(newEnd / cols) * cols;
                newEnd = Math.min(count, newEnd);
            }

            renderStart.value = newStart;
            renderEnd.value = newEnd;

            visibleIndices.clear();
            updateSpacers();

            nextTick(() => {
                if (!mounted || !containerRef.value) {
                    endProgrammaticScroll(seq);
                    resolve();
                    return;
                }
                const currentCount = itemsRef.value.length;
                if (currentCount !== count) {
                    endProgrammaticScroll(seq);
                    resolve();
                    return;
                }

                const children = containerRef.value.querySelectorAll('[data-index]');
                children.forEach(el => {
                    const idx = parseInt(el.dataset.index);
                    if (!isNaN(idx)) {
                        const h = el.getBoundingClientRect().height;
                        if (h > 0) itemHeights.set(idx, h);
                    }
                });
                invalidatePrefixSum();

                let targetTop = paddingTop.value;
                const alignedIndex = Math.floor(index / cols) * cols;

                for (let i = renderStart.value; i < alignedIndex; i += cols) {
                    let rowHeight = 0;
                    for (let j = 0; j < cols && i + j < alignedIndex; j++) {
                        const h = itemHeights.get(i + j) || estimateHeight;
                        if (h > rowHeight) rowHeight = h;
                    }
                    targetTop += rowHeight;
                }

                const itemH = itemHeights.get(index) || estimateHeight;

                if (align === 'center') {
                    targetTop = targetTop - (containerRef.value.clientHeight / 2) + (itemH / 2);
                    const style = window.getComputedStyle(containerRef.value);
                    const containerPaddingTop = parseFloat(style.paddingTop) || 0;
                    targetTop += containerPaddingTop;
                } else if (align === 'top') {
                    targetTop -= 10;
                }

                containerRef.value.scrollTo({ top: Math.max(0, targetTop), behavior });
                observeItems();
                endProgrammaticScroll(seq, behavior === 'smooth' ? 300 : 50);
                resolve();
            });
        });
    };

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
