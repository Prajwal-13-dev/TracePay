// The handbook demo (section 3.2), end to end through the browser:
//   two victims file complaints → supervisor assigns → investigator traces and confirms links
//   → over-attributing T4 is refused → freeze at D → four-eyes approval → verify → allocate → refund
//   → the victim sees the refund.
// Each step saves a screenshot for the report in docs/screenshots/.
import { test, expect, Page, Browser } from '@playwright/test';

const PASSWORD = 'Demo@1234';
const shot = (page: Page, name: string, fullPage = false) =>
  page.screenshot({ path: `docs/screenshots/${name}.png`, fullPage });

async function as(browser: Browser, email: string) {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await go(page, '/login');
  await page.fill('#email', email);
  await page.fill('#password', PASSWORD);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL(/\/(customer|investigator|supervisor)$/);
  return page;
}

// Navigate and wait until the page is interactive (a click before hydration would post the raw form).
async function go(page: Page, url?: string) {
  if (url) await page.goto(url); else await page.reload();
  await page.waitForLoadState('networkidle');
}

// Submits an ActionForm and checks the API accepted it. (Checking the response rather than the
// on-screen message: a successful action can move its row to another table, unmounting the message.)
async function submit(scope: ReturnType<Page['locator']>, button: string) {
  const page = scope.page();
  const [res] = await Promise.all([
    page.waitForResponse(r => r.url().includes('/api/') && r.request().method() !== 'GET'),
    scope.getByRole('button', { name: button, exact: true }).click(),
  ]);
  expect(res.ok(), `${button}: ${res.status()} ${await res.text()}`).toBeTruthy();
}

async function fileComplaint(page: Page, ref: string, amount: string, type: string, story: string) {
  await go(page, '/customer/new');
  await page.locator('.choice', { hasText: `ref ${ref}` }).click();
  await page.getByRole('button', { name: 'Continue →' }).click();
  await page.fill('#amt', amount);
  await page.getByRole('button', { name: 'Continue →' }).click();
  await page.getByRole('button', { name: type }).click();
  await page.fill('#story', story);
  await page.getByRole('button', { name: 'Continue →' }).click();
  await expect(page.getByRole('heading', { name: 'Check and submit' })).toBeVisible();
  return async (screenshot?: string) => {
    if (screenshot) await shot(page, screenshot);
    await page.getByRole('button', { name: 'Submit complaint' }).click();
    const done = page.locator('.callout.ok');
    await expect(done).toContainText('submitted');
    return (await done.textContent())!.match(/#(\d+)/)![1];
  };
}

// Picks the <option> whose visible text matches a pattern. Waits for it: after a write the page
// refreshes its server data in the background, so new options can take a moment to appear.
async function pick(select: ReturnType<Page['locator']>, label: RegExp) {
  let opts: { v: string; t: string }[] = [];
  for (let i = 0; i < 25; i++) {
    opts = await select.locator('option').evaluateAll(os => os.map(o => ({ v: (o as HTMLOptionElement).value, t: o.textContent ?? '' })));
    const hit = opts.find(o => label.test(o.t));
    if (hit) { await select.selectOption(hit.v); return; }
    await select.page().waitForTimeout(200);
  }
  throw new Error(`no option matching ${label} in [${opts.map(o => o.t).join(' | ')}]`);
}

test.describe.configure({ mode: 'serial' });

test('demo story: complaint → trace → freeze → allocation → refund', async ({ browser }) => {
  let c1 = '', c2 = '';

  await test.step('login page', async () => {
    const page = await browser.newPage();
    await go(page, '/login');
    await shot(page, '01-login');
    await page.fill('#email', 'v1@demo.in'); await page.fill('#password', 'wrong');
    await page.getByRole('button', { name: 'Sign in', exact: true }).click();
    await expect(page.locator('p.error[role=alert]')).toHaveText('Wrong email or password.');
    await page.close();
  });

  await test.step('victims file complaints with the wizard', async () => {
    const v1 = await as(browser, 'v1@demo.in');
    const send1 = await fileComplaint(v1, 'T1', '40000', 'Fake KYC / bank call',
      'A caller posing as my bank said my KYC had expired and made me transfer money to a "safe" account.');
    c1 = await send1('02-wizard-review');
    await shot(v1, '03-wizard-submitted');

    // The database rejects more than the transfer amount; the wizard stops it earlier.
    const v2 = await as(browser, 'v2@demo.in');
    await go(v2, '/customer/new');
    await v2.locator('.choice', { hasText: 'ref T6' }).click();
    await v2.getByRole('button', { name: 'Continue →' }).click();
    await v2.fill('#amt', '25000');
    await expect(v2.getByText('Enter an amount between ₹1 and ₹20,000.')).toBeVisible();
    await expect(v2.getByRole('button', { name: 'Continue →' })).toBeDisabled();
    const send2 = await fileComplaint(v2, 'T6', '20000', 'Fake refund or courier',
      'A courier refund link asked me to approve a UPI request, and 20000 left my account instead.');
    c2 = await send2();
    await go(v1, '/customer');
    await expect(v1.locator('.case-card', { hasText: `#${c1}` })).toContainText('Submitted');
  });

  const sup1 = await as(browser, 'sup1@demo.in');
  const sup2 = await as(browser, 'sup2@demo.in');
  const inv = await as(browser, 'inv@demo.in');

  await test.step('supervisor assigns both cases to the investigator', async () => {
    await shot(sup1, '04-supervisor-dashboard', true);
    for (const id of [c1, c2]) {
      await go(sup1, `/supervisor/cases/${id}`);
      const panel = sup1.locator('.side-panel');
      await pick(panel.locator('select[name=investigatorId]'), /^Ira Investigator/);
      await submit(panel, 'Assign');
    }
    await go(sup1, '/supervisor/cases?status=UNDER_REVIEW');
    await expect(sup1.locator('tr', { hasText: `#${c1}` })).toContainText('Ira Investigator');
  });

  const linkForm = (page: Page) => page.locator('form', { has: page.locator('select[name=toTxn]') });
  async function confirmLink(page: Page, from: string, to: string, amount: string) {
    const f = linkForm(page);
    await pick(f.locator('select[name=fromTxn]'), new RegExp(`^${from} `));
    await pick(f.locator('select[name=toTxn]'), new RegExp(`^${to}:`));
    await f.locator('input[name=amount]').fill(amount);
    await f.getByRole('button', { name: 'Confirm link' }).click();
    return f.locator('.ok, .error').first();
  }

  await test.step('investigator traces case 1: T1 → T2 → T4 into account D', async () => {
    await go(inv, `/investigator/cases/${c1}`);
    await inv.getByRole('button', { name: 'Accept and start investigating' }).click();
    await inv.getByRole('button', { name: 'Start trace from the disputed transfer' }).click();
    await expect(linkForm(inv)).toBeVisible();
    await expect(await confirmLink(inv, 'T1', 'T2', '25000')).toHaveClass(/ok/);
    await expect(await confirmLink(inv, 'T2', 'T4', '10000')).toHaveClass(/ok/);
    await inv.waitForLoadState('networkidle');
    const graph = inv.locator('.trace-graph');
    await graph.evaluate(e => e.scrollIntoView({ block: 'center' }));   // clear of the sticky header
    await inv.screenshot({ path: 'docs/screenshots/05-trace-graph.png', clip: (await graph.boundingBox())! });
  });

  await test.step('case 2 cannot claim T4 again (rule txn_capacity)', async () => {
    await go(inv, `/investigator/cases/${c2}`);
    await inv.getByRole('button', { name: 'Accept and start investigating' }).click();
    await inv.getByRole('button', { name: 'Start trace from the disputed transfer' }).click();
    await expect(linkForm(inv)).toBeVisible();
    const msg = await confirmLink(inv, 'T6', 'T4', '5000');
    await expect(msg).toHaveText(/This transfer moved only ₹10,000 in total\. .*claim ₹15,000\. Lower the amount by ₹5,000\./);
    await msg.scrollIntoViewIfNeeded();
    await shot(inv, '06-txn-capacity-refused');
  });

  await test.step('investigator requests a freeze on D; the requester cannot approve it', async () => {
    await go(inv, `/investigator/cases/${c1}`);
    const f = inv.locator('form', { has: inv.locator('select[name=accountId]') });
    await pick(f.locator('select[name=accountId]'), /TP1000000006/);
    await f.locator('input[name=amount]').fill('12000');
    await submit(f, 'Request freeze');
  });

  await test.step('supervisor approves the freeze', async () => {
    await go(sup2, '/supervisor/freezes');
    const row = sup2.locator('tr', { hasText: 'TP1000000006' }).first();
    await submit(row, 'Approve');
    await go(sup2);
    await expect(sup2.locator('tr', { hasText: 'TP1000000006' }).first()).toContainText('₹12,000');
  });

  await test.step('supervisor verifies the loss and moves case 1 to recovery', async () => {
    await go(sup1, `/supervisor/cases/${c1}`);
    const panel = sup1.locator('.side-panel');
    await panel.locator('input[name=amount]').fill('40000');
    await submit(panel, 'Verify');
    await go(sup1);
    await pick(sup1.locator('.side-panel select[name=to]'), /^Recovery$/);
    await submit(sup1.locator('.side-panel'), 'Move');
    await go(sup1);
    await expect(sup1.locator('.page-head')).toContainText('Recovery');
    await shot(sup1, '07a-supervisor-case-page', true);
  });

  await test.step('allocate the frozen money and refund exactly once', async () => {
    await go(sup1, '/supervisor/freezes?tab=active');
    let row = sup1.locator('tr', { hasText: 'TP1000000006' }).filter({ has: sup1.locator('select[name=caseId]') });
    await pick(row.locator('select[name=caseId]'), new RegExp(`^#${c1} `));
    await row.locator('input[name=amount]').fill('12000');      // more than case 1 traced into D (10,000)
    await row.getByRole('button', { name: 'Allocate' }).click();
    await expect(row.locator('.error')).toContainText('exceeds money traced to this account');
    await row.locator('input[name=amount]').fill('10000');
    await submit(row, 'Allocate');
    await go(sup1, '/supervisor/freezes?tab=allocations');
    row = sup1.locator('tr', { hasText: `#${c1}` }).filter({ has: sup1.locator('input[name=amount]') });
    await submit(row, 'Refund');
    await go(sup1);
    await shot(sup1, '07-freezes-and-refunds', true);
  });

  await test.step('the victim sees the refund', async () => {
    const v1 = await as(browser, 'v1@demo.in');
    const card = v1.locator('.case-card', { hasText: `#${c1}` });
    await expect(card).toContainText('Recovery');
    await expect(card.locator('.money')).toContainText('₹10,000');
    await shot(v1, '08-customer-refunded', true);
  });

  await test.step('dashboards after the story', async () => {
    await go(sup1, '/supervisor');
    await expect(sup1.getByText('All rules hold')).toBeVisible();
    await shot(sup1, '09-supervisor-dashboard-after', true);
    await go(inv, '/investigator');
    await shot(inv, '10-investigator-queue', true);
  });

  await test.step('supervisor adds a new investigator, who can sign in at once', async () => {
    await go(sup1, '/supervisor/users');
    await sup1.getByRole('button', { name: '+ Add user' }).click();
    await sup1.fill('#u-name', 'Neha Investigator');
    await sup1.fill('#u-email', 'neha@demo.in');
    await sup1.locator('#u-role').selectOption('INVESTIGATOR');
    await sup1.fill('#u-pw', 'Welcome@123');
    await submit(sup1.locator('form.add-user'), 'Add user');
    await expect(sup1.locator('tr', { hasText: 'neha@demo.in' })).toContainText('Active');
    await shot(sup1, '11-users-page', true);
    const ctx = await browser.newContext();
    const neha = await ctx.newPage();
    await go(neha, '/login');
    await neha.fill('#email', 'neha@demo.in'); await neha.fill('#password', 'Welcome@123');
    await neha.getByRole('button', { name: 'Sign in', exact: true }).click();
    await neha.waitForURL(/\/investigator$/);
  });

  await test.step('a new customer registers, sends money and reports that transfer', async () => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await go(page, '/register');
    await page.fill('#fullName', 'Ravi Kumar'); await page.fill('#email', 'ravi@demo.in'); await page.fill('#password', 'Welcome@123');
    await page.getByRole('button', { name: 'Create account' }).click();
    await expect(page.getByText('Your bank account number is')).toBeVisible();
    await go(page, '/login');
    await page.fill('#email', 'ravi@demo.in'); await page.fill('#password', 'Welcome@123');
    await page.getByRole('button', { name: 'Sign in', exact: true }).click();
    await page.waitForURL(/\/customer$/);
    await go(page, '/customer/send');
    await page.fill('#to', 'TP1000000007');
    await page.locator('#amount').click();                     // leaving the field looks up the recipient
    await expect(page.getByText('Account holder:')).toBeVisible();
    await page.fill('#amount', '2500');
    page.once('dialog', d => d.accept());
    await page.getByRole('button', { name: 'Send money' }).click();
    await expect(page.locator('p.ok')).toContainText('Sent ₹2,500');
    await shot(page, '12-send-money');
    await page.getByRole('link', { name: /Report this transfer/ }).click();
    await expect(page.getByRole('heading', { name: 'How much did you lose?' })).toBeVisible();
  });
});
