export default {
    meta: {
        type: 'problem',
        docs: {
            description: 'Disallow getChatData/db.getChat followed by saveChat/db.saveChat (read-mutate-write race). Use patchChatData or patchChatDataBatch instead.',
            category: 'Architecture',
            recommended: true
        },
        messages: {
            noReadMutateWrite: 'Read-mutate-write race: {{readName}} followed by {{writeName}} in the same scope. Use patchChatData(charId, draft => { /* mutate draft */ }) or patchChatDataBatch(charId, [fn1, fn2]) instead. See docs/rules/database.md.'
        },
        schema: []
    },

    create(context) {
        const READ_NAMES = new Set(['getChatData', 'getChat']);
        const WRITE_NAMES = new Set(['saveChat']);
        const reported = new Set();

        function checkScope(node) {
            let foundRead = null;
            let foundWrite = null;

            function walk(n) {
                if (!n || typeof n !== 'object') return;
                if (n.type === 'CallExpression') {
                    const name = getCallName(n);
                    if (READ_NAMES.has(name) && !foundRead) {
                        foundRead = { node: n, name };
                    }
                    if (WRITE_NAMES.has(name) && !foundWrite) {
                        foundWrite = { node: n, name };
                    }
                }
                for (const key of Object.keys(n)) {
                    if (key === 'parent') continue;
                    const val = n[key];
                    if (Array.isArray(val)) {
                        for (const child of val) {
                            if (child && typeof child === 'object' && child.type) walk(child);
                        }
                    } else if (val && typeof val === 'object' && val.type) {
                        walk(val);
                    }
                }
            }

            walk(node);

            if (foundRead && foundWrite && !reported.has(foundWrite.node)) {
                reported.add(foundWrite.node);
                context.report({
                    node: foundWrite.node,
                    messageId: 'noReadMutateWrite',
                    data: {
                        readName: foundRead.name,
                        writeName: foundWrite.name
                    }
                });
            }
        }

        function getCallName(node) {
            if (node.callee.type === 'Identifier') return node.callee.name;
            if (
                node.callee.type === 'MemberExpression' &&
                node.callee.property?.type === 'Identifier'
            ) return node.callee.property.name;
            return '';
        }

        return {
            FunctionDeclaration(node) { checkScope(node.body); },
            FunctionExpression(node) { checkScope(node.body); },
            ArrowFunctionExpression(node) { checkScope(node.body); }
        };
    }
};
