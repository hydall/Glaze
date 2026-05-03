/**
 * AsyncOperationScope — decouples UI subscription from operation lifetime.
 *
 * Key invariant: unsubscribe() never calls .abort().
 * Only explicit user action (stop button) triggers abort().
 *
 * Usage:
 *   const scope = createAsyncScope();
 *
 *   // Service layer: register a running operation
 *   scope.register('gen:char42:session1', controller);
 *
 *   // Component layer: subscribe to results
 *   scope.subscribe('gen:char42:session1', (update) => { ... });
 *
 *   // Component unmounts: only disconnects, operation continues
 *   scope.unsubscribe('gen:char42:session1');
 *
 *   // User clicks stop: aborts the operation
 *   scope.abort('gen:char42:session1');
 *
 *   // Operation completes normally
 *   scope.complete('gen:char42:session1', result);
 */

export function createAsyncScope() {
    const operations = new Map();

    /**
     * Subscribe to operation updates. Called by component layer.
     * @param {string} opId - Operation identifier
     * @param {Function} onUpdate - Callback for updates
     */
    function subscribe(opId, onUpdate) {
        const op = operations.get(opId);
        if (op) {
            op.subscriber = onUpdate;
        }
    }

    /**
     * Unsubscribe from operation updates. Called in onUnmounted.
     * Does NOT abort the operation — only disconnects the UI.
     * @param {string} opId - Operation identifier
     */
    function unsubscribe(opId) {
        const op = operations.get(opId);
        if (op) {
            op.subscriber = null;
        }
    }

    /**
     * Register a running operation. Called by service layer.
     * @param {string} opId - Operation identifier
     * @param {AbortController} controller - Abort controller for the operation
     */
    function register(opId, controller) {
        operations.set(opId, {
            controller,
            subscriber: null,
            completed: false
        });
    }

    /**
     * Mark an operation as completed. Called by service layer.
     * @param {string} opId - Operation identifier
     * @param {*} [result] - Optional result to send to subscriber
     */
    function complete(opId, result) {
        const op = operations.get(opId);
        if (!op) return;
        op.completed = true;
        if (op.subscriber) {
            op.subscriber({ type: 'complete', result });
        }
        operations.delete(opId);
    }

    /**
     * Abort an operation. Only called by explicit user action (stop button).
     * NOT called on component unmount.
     * @param {string} opId - Operation identifier
     */
    function abort(opId) {
        const op = operations.get(opId);
        if (!op || op.completed) return;
        op.controller?.abort();
        if (op.subscriber) {
            op.subscriber({ type: 'abort' });
        }
        operations.delete(opId);
    }

    /**
     * Send an update to the subscriber. Called by service layer.
     * @param {string} opId - Operation identifier
     * @param {*} update - Update payload
     */
    function emit(opId, update) {
        const op = operations.get(opId);
        if (!op || op.completed) return;
        if (op.subscriber) {
            op.subscriber({ type: 'update', payload: update });
        }
    }

    /**
     * Check if an operation is currently active.
     * @param {string} opId - Operation identifier
     * @returns {boolean}
     */
    function isActive(opId) {
        const op = operations.get(opId);
        return !!op && !op.completed;
    }

    /**
     * Get the AbortController for an operation.
     * @param {string} opId - Operation identifier
     * @returns {AbortController|null}
     */
    function getController(opId) {
        return operations.get(opId)?.controller ?? null;
    }

    /**
     * Get the subscriber callback for an operation.
     * @param {string} opId - Operation identifier
     * @returns {Function|null}
     */
    function getSubscriber(opId) {
        return operations.get(opId)?.subscriber ?? null;
    }

    /**
     * Clean up all operations. Called on app shutdown.
     */
    function clearAll() {
        for (const op of operations.values()) {
            if (op.subscriber) op.subscriber = null;
        }
        operations.clear();
    }

    return {
        subscribe,
        unsubscribe,
        register,
        complete,
        abort,
        emit,
        isActive,
        getController,
        getSubscriber,
        clearAll
    };
}
