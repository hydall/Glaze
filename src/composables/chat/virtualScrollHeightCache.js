export function createHeightCache({ getItemLength, getColumns, estimateHeight }) {
    const itemHeights = new Map();
    let prefixSumCache = null;
    let prefixSumDirty = true;

    function invalidate() {
        prefixSumDirty = true;
    }

    function ensure() {
        if (!prefixSumDirty && prefixSumCache) return prefixSumCache;

        const count = getItemLength();
        const cols = getColumns();
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
        const sums = ensure();
        const cols = getColumns();
        const rowIdx = Math.floor(index / cols);
        return rowIdx < sums.length ? sums[rowIdx] : sums[sums.length - 1];
    }

    function getTotalHeight() {
        const sums = ensure();
        return sums[sums.length - 1];
    }

    function getRenderedContentHeight(start, end) {
        const sums = ensure();
        const cols = getColumns();
        const startRow = Math.floor(start / cols);
        const endRow = Math.floor(end / cols);
        const s = startRow < sums.length ? sums[startRow] : 0;
        const e = endRow < sums.length ? sums[endRow] : sums[sums.length - 1];
        return e - s;
    }

    function setHeight(index, height) {
        if (height > 0 && itemHeights.get(index) !== height) {
            itemHeights.set(index, height);
            invalidate();
        }
    }

    function getHeight(index) {
        return itemHeights.get(index) || estimateHeight;
    }

    function hasHeight(index) {
        return itemHeights.has(index);
    }

    function findRowAtScrollTop(scrollTop) {
        const sums = ensure();
        for (let r = 0; r < sums.length - 1; r++) {
            if (sums[r + 1] > scrollTop) return r;
        }
        return -1;
    }

    function pruneStale() {
        const count = getItemLength();
        for (const key of itemHeights.keys()) {
            if (key >= count) itemHeights.delete(key);
        }
    }

    function clear() {
        itemHeights.clear();
        invalidate();
    }

    function computeSpacers(start, end) {
        pruneStale();
        const sums = ensure();
        const cols = getColumns();
        const total = getItemLength();

        const startRow = Math.floor(start / cols);
        const top = startRow < sums.length ? sums[startRow] : 0;

        let rowStart = end;
        if (cols > 1) {
            rowStart = Math.ceil(end / cols) * cols;
        }
        const endRow = Math.floor(rowStart / cols);
        const totalRows = sums.length - 1;
        const bottom = endRow < totalRows ? sums[totalRows] - sums[Math.min(endRow, totalRows)] : 0;

        return { top, bottom };
    }

    function computeTargetTop(renderStart, targetIndex, cols) {
        const alignedIndex = Math.floor(targetIndex / cols) * cols;
        let targetTop = 0;
        for (let i = renderStart; i < alignedIndex; i += cols) {
            let rowHeight = 0;
            for (let j = 0; j < cols && i + j < alignedIndex; j++) {
                const h = getHeight(i + j);
                if (h > rowHeight) rowHeight = h;
            }
            targetTop += rowHeight;
        }
        return targetTop;
    }

    return {
        invalidate,
        ensure,
        getHeightUpTo,
        getTotalHeight,
        getRenderedContentHeight,
        setHeight,
        getHeight,
        hasHeight,
        findRowAtScrollTop,
        pruneStale,
        clear,
        computeSpacers,
        computeTargetTop
    };
}
