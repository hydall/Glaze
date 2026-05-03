import js from '@eslint/js';
import pluginVue from 'eslint-plugin-vue';
import noAbortInUnmount from './eslint-rules/no-abort-in-unmount.js';
import noReadMutateWrite from './eslint-rules/no-read-mutate-write.js';

const localRulesPlugin = {
    rules: {
        'no-abort-in-unmount': noAbortInUnmount,
        'no-read-mutate-write': noReadMutateWrite
    }
};

export default [
    {
        ignores: [
            'dist/**',
            'dist_electron/**',
            'node_modules/**',
            'android/**',
            'ios/**',
            'public/**',
            'src/gp-tokenizer/**',
            'src/tokenizers/**'
        ]
    },
    js.configs.recommended,
    ...pluginVue.configs['flat/recommended'],
    {
        plugins: {
            'glaze': localRulesPlugin
        },
        files: ['**/*.{js,mjs,cjs}', '**/*.vue'],
        languageOptions: {
            ecmaVersion: 2022,
            sourceType: 'module',
            globals: {
                window: 'readonly',
                document: 'readonly',
                navigator: 'readonly',
                console: 'readonly',
                fetch: 'readonly',
                setTimeout: 'readonly',
                setInterval: 'readonly',
                clearTimeout: 'readonly',
                clearInterval: 'readonly',
                requestAnimationFrame: 'readonly',
                cancelAnimationFrame: 'readonly',
                URL: 'readonly',
                URLSearchParams: 'readonly',
                Blob: 'readonly',
                File: 'readonly',
                FileReader: 'readonly',
                FormData: 'readonly',
                Headers: 'readonly',
                Response: 'readonly',
                Request: 'readonly',
                AbortController: 'readonly',
                AbortSignal: 'readonly',
                localStorage: 'readonly',
                sessionStorage: 'readonly',
                indexedDB: 'readonly',
                crypto: 'readonly',
                Worker: 'readonly',
                SharedArrayBuffer: 'readonly',
                Atomics: 'readonly',
                BigInt: 'readonly',
                WebSocket: 'readonly',
                Event: 'readonly',
                CustomEvent: 'readonly',
                MessageChannel: 'readonly',
                MessagePort: 'readonly',
                performance: 'readonly',
                caches: 'readonly',
                alert: 'readonly',
                confirm: 'readonly',
                prompt: 'readonly',
                matchMedia: 'readonly',
                IntersectionObserver: 'readonly',
                ResizeObserver: 'readonly',
                MutationObserver: 'readonly',
                history: 'readonly',
                location: 'readonly',
                screen: 'readonly',
                Capacitor: 'readonly',
                CapacitorDatePicker: 'readonly',
                Image: 'readonly',
                self: 'readonly',
                TextEncoder: 'readonly',
                TextDecoder: 'readonly',
                DOMException: 'readonly',
                btoa: 'readonly',
                atob: 'readonly',
                Notification: 'readonly',
                queueMicrotask: 'readonly',
                DocumentFragment: 'readonly',
                HTMLElement: 'readonly',
                structuredClone: 'readonly',
                __APP_VERSION__: 'readonly',
                process: 'readonly',
                __static: 'readonly',
                require: 'readonly',
                defineProps: 'readonly',
                defineEmits: 'readonly',
                defineExpose: 'readonly',
                withDefaults: 'readonly'
            }
        },
        rules: {
            'no-use-before-define': ['error', {
                functions: false,
                variables: true,
                classes: true
            }],
            'no-undef': 'error',
            'no-unused-vars': ['warn', {
                argsIgnorePattern: '^_',
                varsIgnorePattern: '^_'
            }],
            'no-redeclare': 'error',
            'no-shadow': 'warn',
            'no-var': 'error',
            'prefer-const': ['warn', { destructuring: 'all' }],
            'eqeqeq': ['error', 'always'],
            'curly': ['error', 'multi-line'],
            'no-eval': 'error',
            'no-implied-eval': 'error',
            'no-new-func': 'error',
            'no-with': 'error',
            'no-throw-literal': 'error',
            'no-duplicate-imports': 'error',
            'no-self-compare': 'error',
            'no-constant-binary-expression': 'error',
            'no-constructor-return': 'error',
            'no-promise-executor-return': 'error',
            'no-unreachable-loop': 'error',
            'no-unsafe-optional-chaining': 'error',
            'no-unused-private-class-members': 'warn',
            'dot-notation': ['warn', { allowKeywords: true }],
            'vue/no-use-computed-property-like-method': 'error',
            'vue/no-async-in-computed-properties': 'error',
            'vue/no-side-effects-in-computed-properties': 'error',
            'vue/no-mutating-props': 'error',
            'vue/no-v-html': 'off',
            'vue/multi-word-component-names': 'off',
            'vue/require-default-prop': 'off',
            'vue/no-setup-props-destructure': 'off',
            'vue/max-attributes-per-line': 'off',
            'vue/single-line-html-element-content-newline': 'off',
            'vue/multiline-html-element-content-newline': 'off',
            'vue/html-self-closing': 'off',
            'html-indent': 'off',
            'vue/html-indent': 'off',
            'vue/html-closing-bracket-spacing': 'off',
            'vue/html-closing-bracket-newline': 'off',
            'vue/first-attribute-linebreak': 'off',
            'vue/first-attribute-line': 'off',
            'vue/attributes-order': 'off',
            'no-empty': 'off',
            'glaze/no-abort-in-unmount': 'error',
            'glaze/no-read-mutate-write': 'error'
        }
    }
];
