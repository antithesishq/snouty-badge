/* Browser smoke test for the phone page. Start the demo server, then run with
   NODE_PATH pointing to a Playwright installation; BADGE_BROWSER_URL and
   PLAYWRIGHT_CHROMIUM_EXECUTABLE may override the defaults. */
const assert = require('node:assert/strict');
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
    args: ['--no-sandbox'],
  });
  const url = process.env.BADGE_BROWSER_URL || 'http://127.0.0.1:8187/';
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    let fits = 0;
    let deploys = 0;
    await page.route('**/api/fit', async route => {
      fits++;
      if (fits === 1) {
        await route.fulfill({ status: 503, contentType: 'application/json', body: '{"error":"temporary"}' });
      } else {
        await route.continue();
      }
    });
    page.on('request', request => {
      if (request.url().endsWith('/api/deploy')) deploys++;
    });
    await page.goto(url);
    await page.waitForSelector('#demo-banner:not(.hidden)');
    await page.locator('#sets .tap').first().click();
    const expandedFocus = await page.evaluate(() => document.activeElement.getAttribute('data-focus-key'));
    assert.equal(expandedFocus, 'set:demo');
    await page.locator('#sets .danger').first().focus();
    await page.waitForTimeout(1100); // status polling must retain the focused control
    assert.equal(await page.evaluate(() => document.activeElement.getAttribute('data-focus-key')), 'remove:demo');
    await page.locator('#sets .danger').first().click();
    assert.equal(await page.evaluate(() => document.activeElement.getAttribute('data-focus-key')), 'remove:demo');

    await page.locator('#library input[type=checkbox]').first().check();
    await page.waitForSelector('#retry-fit:not(.hidden)');
    await page.waitForSelector('#deploy-sel:not([disabled])', { timeout: 10000 });
    assert.ok(fits >= 2);
    assert.match(await page.locator('#fitline').innerText(), /of .* entries/);

    const deploy = page.locator('#sets button:not(.tap):not(.danger)').first();
    await deploy.click();
    assert.equal(deploys, 0, 'first tap must not deploy');
    await deploy.click();
    await page.waitForTimeout(200);
    assert.equal(deploys, 1, 'second tap deploys');
    assert.match(await page.locator('#operation').innerText(), /deploy demo (accepted|completed)/);
    assert.deepEqual(errors, []);
    console.log('browser regression passed: focus, fit retry, deploy confirmation, operation result');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
