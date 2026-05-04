import { nextTick } from 'vue';

export function useVirtualScrollNavigation({
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
}) {
    let programmaticSeq = 0;

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

    function setRenderWindow(index, count) {
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
        realVisibleIndices.clear();
        cache.invalidate();
        updateSpacers();
    }

    function measureRenderedChildren() {
        if (!containerRef.value) return;
        const children = containerRef.value.querySelectorAll('[data-index]');
        children.forEach(el => {
            const idx = parseInt(el.dataset.index);
            if (!isNaN(idx)) {
                const h = el.getBoundingClientRect().height;
                cache.setHeight(idx, h);
            }
        });
    }

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

            setRenderWindow(index, count);

            nextTick(() => {
                if (!mounted || !containerRef.value) {
                    resolve();
                    return;
                }
                if (itemsRef.value.length !== count) {
                    endProgrammaticScroll(seq);
                    resolve();
                    return;
                }

                measureRenderedChildren();

                const cols = columns.value;
                const targetTop = paddingTop.value + cache.computeTargetTop(renderStart.value, index, cols) + (anchor.offset || 0);

                const style = window.getComputedStyle(containerRef.value);
                const containerPaddingTop = parseFloat(style.paddingTop) || 0;

                containerRef.value.scrollTop = targetTop + containerPaddingTop;
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
        realVisibleIndices.clear();
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
                            targetTop = targetTop - containerPaddingTop - 10;
                        }

                        containerRef.value.scrollTo({ top: Math.max(0, targetTop), behavior });
                    }
                    endProgrammaticScroll(seq, behavior === 'smooth' ? 300 : 50);
                    resolve();
                });
                return;
            }

            setRenderWindow(index, count);

            nextTick(() => {
                if (!mounted || !containerRef.value) {
                    endProgrammaticScroll(seq);
                    resolve();
                    return;
                }
                if (itemsRef.value.length !== count) {
                    endProgrammaticScroll(seq);
                    resolve();
                    return;
                }

                measureRenderedChildren();

                const cols = columns.value;
                let targetTop = paddingTop.value + cache.computeTargetTop(renderStart.value, index, cols);
                const itemH = cache.getHeight(index);

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

    return {
        getScrollAnchor,
        scrollToAnchor,
        scrollToBottom,
        scrollToIndex
    };
}
