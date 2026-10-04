// Playwright config for the WebView asset tests.
//
// These tests load the *real* modules out of `assets/chat_webview/` in a
// headless Chromium and assert on what the browser actually built: the DOM
// inside the message shadow root, the CSS the browser resolved, and what a
// click does. Nothing here reads a source file as a string — that is what the
// Dart asset tests do, and it is why rendering regressions used to reach
// users before CI.
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './specs',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: process.env.CI ? [['list'], ['github']] : [['list']],
  timeout: 20_000,
  expect: { timeout: 5_000 },
  use: {
    baseURL: 'http://127.0.0.1:4176',
    trace: 'retain-on-failure',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  ],
  webServer: {
    command: 'node harness/server.js',
    url: 'http://127.0.0.1:4176/test/webview_js/harness/harness.html',
    reuseExistingServer: !process.env.CI,
    stdout: 'ignore',
    stderr: 'pipe',
  },
});
