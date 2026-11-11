/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The browser tests' configuration (docs/design-web.md, "Verification and
 * testing"). test/host/web_browser_test.rb runs them from the staged client
 * and names, in the environment, the front end's origin and the Chromium that
 * `tools/erx fetch` verified against deps.lock; Playwright never downloads a
 * browser of its own. The files end in .spec.ts, so Node's test runner, which
 * runs web/**\/*.test.ts, leaves them to Playwright.
 */

import { defineConfig } from '@playwright/test';

function required(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === '') throw new Error(`${name} is not set: test/host/web_browser_test.rb runs these tests`);
  return value;
}

export default defineConfig({
  testDir: '.',
  testMatch: '*.spec.ts',
  workers: 1,
  retries: 0,
  forbidOnly: true,
  reporter: [['list']],
  outputDir: required('ERX_BROWSER_OUTPUT'),
  use: {
    baseURL: required('ERX_WEB_ORIGIN'),
    browserName: 'chromium',
    headless: true,
    launchOptions: { executablePath: required('ERX_CHROMIUM') },
    serviceWorkers: 'block',
    trace: 'off',
    screenshot: 'off',
    video: 'off',
  },
});
