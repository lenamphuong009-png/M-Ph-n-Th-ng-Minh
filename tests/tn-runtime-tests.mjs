// Chạy: TN_SUPABASE_JS=<đường dẫn supabase.js UMD 2.117.3, đúng SRI> node tests/tn-runtime-tests.mjs .
// Cần Playwright + Chromium. Mọi yêu cầu mạng bị chặn và giả lập; không gọi Supabase thật.
// Kiểm thử runtime: Chromium + tên miền giả lập + chặn MỌI yêu cầu mạng (Supabase giả, không gọi máy chủ thật).
// Dùng: node runtime-tests.mjs <đường-dẫn-repo>
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)('playwright');
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, cpSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, extname } from 'node:path';

const REPO = process.argv[2] || '.';
const SB_JS = (() => { if (!process.env.TN_SUPABASE_JS) { console.error('Thiếu TN_SUPABASE_JS (supabase-js 2.117.3 UMD).'); process.exit(2); } return readFileSync(process.env.TN_SUPABASE_JS); })();
const STG_REF = 'mhyadympadwxzuwwlnps', PRD_REF = 'jswnebhtxuvyzmcpruad';
const IDS = { stgAdmin: 'bd773533-d3c1-4c26-86d2-2ea190623ae2', prdAdmin: 'aaaaaaaa-0000-4000-8000-000000000001',
  stgPublic: 'aaaaaaaa-0000-4000-8000-000000000002', prdPublic: 'aaaaaaaa-0000-4000-8000-000000000003' };

// ---------- Dựng 4 bản build (production/public CHỈ trong bản clone tạm, khóa giả) ----------
const work = mkdtempSync(join(tmpdir(), 'tnr-'));
execFileSync('git', ['clone', '-q', REPO, join(work, 'src')]);
const src = join(work, 'src');
execFileSync('git', ['-C', src, 'checkout', '-q', execFileSync('git', ['-C', REPO, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()]);
const cfgPath = join(src, 'scripts/tn-build-config.json');
const cfg = JSON.parse(readFileSync(cfgPath, 'utf8'));
cfg.environments.production = { supabase_ref: PRD_REF, supabase_url: 'https://' + PRD_REF + '.supabase.co', publishable_key: 'sb_publishable_TESTONLY_khong_phai_khoa_that' };
cfg.sites[IDS.prdAdmin] = { site_name: 'test-prd-admin', env: 'production', role: 'admin', allow: [{ context: 'production', branch: 'release-v1' }] };
cfg.sites[IDS.stgPublic] = { site_name: 'test-stg-public', env: 'staging', role: 'public', allow: [{ context: 'production', branch: 'engine-v1' }] };
cfg.sites[IDS.prdPublic] = { site_name: 'test-prd-public', env: 'production', role: 'public', allow: [{ context: 'production', branch: 'release-v1' }] };
writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
execFileSync('git', ['-C', src, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qam', 'test-only config']);
function build(name, env) {
  const r = spawnSync('node', ['scripts/tn-build.mjs'], { cwd: src, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: process.env.HOME, ...env } });
  if (r.status !== 0) throw new Error('build ' + name + ' lỗi: ' + r.stdout + r.stderr);
  const out = join(work, name); cpSync(join(src, 'dist'), out, { recursive: true }); return out;
}
const common = { CONTEXT: 'production', PULL_REQUEST: 'false', COMMIT_REF: 'test' };
const D = {
  stgAdmin: build('stgAdmin', { ...common, SITE_ID: IDS.stgAdmin, SITE_NAME: 'phyverse-staging-tn', BRANCH: 'engine-v1', TN_DEPLOY_ENV: 'staging', TN_SITE_ROLE: 'admin' }),
  prdAdmin: build('prdAdmin', { ...common, SITE_ID: IDS.prdAdmin, SITE_NAME: 'test-prd-admin', BRANCH: 'release-v1', TN_DEPLOY_ENV: 'production', TN_SITE_ROLE: 'admin' }),
  stgPublic: build('stgPublic', { ...common, SITE_ID: IDS.stgPublic, SITE_NAME: 'test-stg-public', BRANCH: 'engine-v1', TN_DEPLOY_ENV: 'staging', TN_SITE_ROLE: 'public' }),
  prdPublic: build('prdPublic', { ...common, SITE_ID: IDS.prdPublic, SITE_NAME: 'test-prd-public', BRANCH: 'release-v1', TN_DEPLOY_ENV: 'production', TN_SITE_ROLE: 'public' }),
  raw: src // tệp gốc, KHÔNG có tn-build.js
};

// ---------- Máy chủ giả ----------
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript' };
const GRAVE = { id: 'd0000000-0000-4000-8000-0000000000a1', memorial_slug: 'kiem-thu-a', deceased_name: '[THỬ] Hồ sơ giả', saint_name: null,
  birth_label: null, death_label: null, epigraph: null, honorific: null, portrait_path: null, timeline: [], wishes: [], footer_note: null,
  is_published: true, incense_count: 0 };
async function newPage(browser, distDir, opts = {}) {
  const ctx = await browser.newContext();
  const sbCalls = [];
  await ctx.route('**/*', async route => {
    const u = new URL(route.request().url());
    if (u.hostname === 'cdn.jsdelivr.net' && u.pathname.includes('supabase-js@2.117.3')) return route.fulfill({ status: 200, contentType: 'application/javascript', body: SB_JS, headers: { 'access-control-allow-origin': '*' } });
    if (u.hostname.endsWith('.supabase.co')) {
      sbCalls.push(u.hostname.split('.')[0] + ' ' + route.request().method() + ' ' + u.pathname);
      const H = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' };
      if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: H });
      if (u.pathname === '/auth/v1/token') {
        if (opts.login) return route.fulfill({ status: 200, contentType: 'application/json', headers: H, body: JSON.stringify({
          access_token: 'x.' + Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 3600, sub: 'u1' })).toString('base64url') + '.y',
          token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, refresh_token: 'r',
          user: { id: '00000000-0000-4000-8000-0000000000u1'.replace('u1', 'f1'), email: 'kiemthu@example.invalid', aud: 'authenticated', role: 'authenticated' } }) });
        return route.fulfill({ status: 400, contentType: 'application/json', headers: H, body: JSON.stringify({ error: 'invalid_grant', error_description: 'Invalid login credentials', code: 'invalid_credentials', msg: 'Invalid login credentials' }) });
      }
      if (u.pathname.startsWith('/rest/v1/graves')) return route.fulfill({ status: 200, contentType: 'application/json', headers: H, body: JSON.stringify(opts.graves || [GRAVE]) });
      if (u.pathname.startsWith('/rest/v1/grave_managers')) return route.fulfill({ status: 200, contentType: 'application/json', headers: H, body: JSON.stringify([{ grave_id: GRAVE.id, role: 'owner', revoked_at: null, expires_at: null }]) });
      if (u.pathname.startsWith('/rest/v1/memorial_creators')) return route.fulfill({ status: 200, contentType: 'application/json', headers: H, body: JSON.stringify(route.request().headers()['accept']?.includes('vnd.pgrst.object') ? { user_id: 'x' } : [{ user_id: 'x' }]) });
      return route.fulfill({ status: 200, contentType: 'application/json', headers: H, body: '[]' });
    }
    if (u.hostname.includes('fonts.')) return route.fulfill({ status: 200, contentType: 'text/css', body: '' });
    // tên miền thử → phục vụ từ thư mục build
    let p = u.pathname === '/' ? '/index.html' : u.pathname;
    const f = join(distDir, decodeURIComponent(p));
    if (!f.startsWith(distDir) || !existsSync(f) || p.includes('..')) return route.fulfill({ status: 404, body: 'not found' });
    return route.fulfill({ status: 200, contentType: MIME[extname(f)] || 'application/octet-stream', body: readFileSync(f) });
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  return { ctx, page, sbCalls, errors };
}
const results = [];
async function rcase(id, desc, fn) {
  try { const r = await fn(); results.push({ id, desc, ok: r === true, note: r === true ? '' : r }); }
  catch (e) { results.push({ id, desc, ok: false, note: 'NGOẠI LỆ: ' + e.message.slice(0, 200) }); }
}
const browser = await chromium.launch();
const txt = async (page, sel) => (await page.locator(sel).first().textContent().catch(() => '')) || '';
const visible = async (page, sel) => page.locator(sel).first().isVisible().catch(() => false);

async function adminCase(dist, host, expectEnv) {
  const { ctx, page, sbCalls, errors } = await newPage(browser, dist);
  await page.goto('https://' + host + '/admin.html'); await page.waitForTimeout(800);
  const badge = (await txt(page, '#envBadge')).trim(), boot = (await txt(page, '#bootMsg')).trim();
  let res;
  if (expectEnv) {
    if (!(await visible(page, '#viewLogin'))) res = 'không hiện màn đăng nhập (boot: ' + boot + ')';
    else {
      await page.fill('#loginEmail', 'kiemthu@example.invalid'); await page.fill('#loginPassword', 'sai-mat-khau');
      await page.click('#loginBtn'); await page.waitForTimeout(800);
      const refs = [...new Set(sbCalls.map(c => c.split(' ')[0]))];
      const want = expectEnv === 'staging' ? STG_REF : PRD_REF;
      const label = expectEnv === 'staging' ? 'Staging' : 'Production';
      if (badge !== label) res = 'nhãn môi trường = "' + badge + '"';
      else if (JSON.stringify(refs) !== JSON.stringify([want])) res = 'gọi Supabase: ' + JSON.stringify(refs);
      else if (!/không đúng/.test(await txt(page, '#loginMsg'))) res = 'thông báo đăng nhập sai: ' + await txt(page, '#loginMsg');
      else res = true;
    }
  } else {
    if (sbCalls.length) res = 'CÓ gọi Supabase: ' + sbCalls[0];
    else if (!/chưa được cấu hình/.test(boot)) res = 'không thấy thông báo từ chối (boot: ' + boot + ')';
    else if (badge !== 'Chưa xác định môi trường') res = 'nhãn = ' + badge;
    else if (await visible(page, '#viewLogin')) res = 'vẫn hiện màn đăng nhập';
    else res = true;
  }
  if (res === true && errors.filter(e => !/Môi trường chưa được cấu hình/.test(e)).length) res = 'lỗi JS: ' + errors[0];
  await ctx.close(); return res;
}
async function indexCase(dist, url, expectRef) {
  const { ctx, page, sbCalls } = await newPage(browser, dist);
  await page.goto(url); await page.waitForTimeout(900);
  const refs = [...new Set(sbCalls.map(c => c.split(' ')[0]))];
  await ctx.close();
  if (expectRef) return JSON.stringify(refs) === JSON.stringify([expectRef]) ? true : 'gọi Supabase: ' + JSON.stringify(refs);
  return refs.length === 0 ? true : 'CÓ gọi Supabase: ' + JSON.stringify(refs);
}

await rcase('R1', 'Quản trị staging quanly.phyverse.io.vn ↔ build staging/admin → Staging, chỉ gọi ' + STG_REF, () => adminCase(D.stgAdmin, 'quanly.phyverse.io.vn', 'staging'));
await rcase('R2', 'Quản trị production quanly.phyverse.com.vn ↔ build production/admin → Production, chỉ gọi ' + PRD_REF, () => adminCase(D.prdAdmin, 'quanly.phyverse.com.vn', 'production'));
await rcase('R3', 'Tên miền production gắn nhầm vào site staging → TỪ CHỐI', () => adminCase(D.stgAdmin, 'quanly.phyverse.com.vn', null));
await rcase('R4', 'quanly.phyverse.io.vn trên bản build production → TỪ CHỐI', () => adminCase(D.prdAdmin, 'quanly.phyverse.io.vn', null));
await rcase('R5', 'Deploy Preview deploy-preview-7--phyverse-staging-tn.netlify.app → Staging', () => adminCase(D.stgAdmin, 'deploy-preview-7--phyverse-staging-tn.netlify.app', 'staging'));
await rcase('R5b', 'Deploy Preview của site khác (glittery-swan) → TỪ CHỐI', () => adminCase(D.stgAdmin, 'deploy-preview-7--glittery-swan-23c695.netlify.app', null));
await rcase('R5c', 'Branch deploy engine-v1--phyverse-staging-tn.netlify.app → TỪ CHỐI', () => adminCase(D.stgAdmin, 'engine-v1--phyverse-staging-tn.netlify.app', null));
await rcase('R6', 'Tên miền site production *.netlify.app (ngoài danh sách) → TỪ CHỐI', () => adminCase(D.prdAdmin, 'phyverse-memorial-prod.netlify.app', null));
await rcase('R6b', 'Tên miền lạ evil.example.com → TỪ CHỐI', () => adminCase(D.stgAdmin, 'evil.example.com', null));
await rcase('R6c', 'Tên miền cũ engine-v1--glittery-swan-23c695.netlify.app (đã gỡ) → TỪ CHỐI', () => adminCase(D.stgAdmin, 'engine-v1--glittery-swan-23c695.netlify.app', null));
await rcase('R6d', 'Trang quản trị trên bản build public → TỪ CHỐI (và public không có admin.html)', async () => {
  return existsSync(join(D.prdPublic, 'admin.html')) ? 'build public CÓ admin.html' : true; });
await rcase('R7', 'Công khai staging kiem-thu-a.phyverse.io.vn ↔ build staging/public → gọi ' + STG_REF, () => indexCase(D.stgPublic, 'https://kiem-thu-a.phyverse.io.vn/', STG_REF));
await rcase('R7b', 'Công khai staging với slug không có tiền tố thử → TỪ CHỐI', () => indexCase(D.stgPublic, 'https://nguyen-van-a.phyverse.io.vn/', null));
await rcase('R7c', 'Công khai production nguyen-van-a.phyverse.io.vn ↔ build production/public → gọi ' + PRD_REF, () => indexCase(D.prdPublic, 'https://nguyen-van-a.phyverse.io.vn/', PRD_REF));
await rcase('R7d', 'Công khai production với slug thử kiem-thu-a → TỪ CHỐI', () => indexCase(D.prdPublic, 'https://kiem-thu-a.phyverse.io.vn/', null));
await rcase('R8', 'Tên miền khách trên bản build admin (staging) → TỪ CHỐI', () => indexCase(D.stgAdmin, 'https://kiem-thu-a.phyverse.io.vn/', null));
await rcase('R9', 'tuongniem.phyverse.io.vn chạy mã Memorial Engine → TỪ CHỐI', () => indexCase(D.prdPublic, 'https://tuongniem.phyverse.io.vn/', null));
await rcase('R9b', 'Tên miền nhiều cấp a.b.phyverse.io.vn → TỪ CHỐI', () => indexCase(D.prdPublic, 'https://a.kiem-thu-a.phyverse.io.vn/', null));
await rcase('R10', 'Tệp gốc KHÔNG có tn-build.js (quanly.phyverse.io.vn/admin.html) → TỪ CHỐI', () => adminCase(D.raw, 'quanly.phyverse.io.vn', null));
await rcase('R10b', 'Tệp gốc KHÔNG có tn-build.js (index ?memorial=) → TỪ CHỐI', () => indexCase(D.raw, 'https://quanly.phyverse.io.vn/index.html?memorial=kiem-thu-a', null));
await rcase('R11', 'Xem trước trên quản trị staging (?memorial=…&preview=1) → gọi ' + STG_REF, () => indexCase(D.stgAdmin, 'https://quanly.phyverse.io.vn/index.html?memorial=kiem-thu-a&preview=1', STG_REF));
await rcase('R11b', 'Xem trước trên quản trị production → gọi ' + PRD_REF, () => indexCase(D.prdAdmin, 'https://quanly.phyverse.com.vn/index.html?memorial=nguyen-van-a&preview=1', PRD_REF));
await rcase('R12', '?memorial= trên quanly.phyverse.com.vn với build staging → TỪ CHỐI', () => indexCase(D.stgAdmin, 'https://quanly.phyverse.com.vn/index.html?memorial=kiem-thu-a', null));

// ---------- Chức năng quản trị hiện có (đăng nhập giả → danh sách → tạo trang) ----------
async function adminFlow(dist, host, env) {
  const { ctx, page, sbCalls, errors } = await newPage(browser, dist, { login: true });
  await page.goto('https://' + host + '/admin.html'); await page.waitForTimeout(700);
  await page.fill('#loginEmail', 'kiemthu@example.invalid'); await page.fill('#loginPassword', 'x');
  await page.click('#loginBtn'); await page.waitForTimeout(1500);
  if (!(await visible(page, '#viewList'))) { await ctx.close(); return 'không vào được danh sách. lỗi: ' + errors.join(' | ') + ' boot ' + await txt(page, '#loginMsg'); }
  const listTxt = await txt(page, '#listBox');
  await page.fill('#newName', 'Nguyễn Văn A'); await page.waitForTimeout(150);
  const autoSlug = await page.inputValue('#newSlug');
  const prev1 = await txt(page, '#newSlugPreview');
  await page.fill('#newSlug', env === 'staging' ? 'nguyen-van-a' : 'kiem-thu-a'); await page.dispatchEvent('#newSlug', 'input'); await page.waitForTimeout(100);
  const before = sbCalls.filter(c => c.includes('/rpc/create_memorial')).length;
  await page.click('#createBtn'); await page.waitForTimeout(500);
  const msg = await txt(page, '#createMsg');
  const after = sbCalls.filter(c => c.includes('/rpc/create_memorial')).length;
  const refs = [...new Set(sbCalls.map(c => c.split(' ')[0]))];
  await ctx.close();
  const want = env === 'staging' ? STG_REF : PRD_REF;
  if (!listTxt.includes('[THỬ] Hồ sơ giả')) return 'danh sách không hiện hồ sơ giả: ' + listTxt.slice(0, 80);
  if (env === 'staging' && autoSlug !== 'kiem-thu-nguyen-van-a') return 'slug tự sinh staging = ' + autoSlug;
  if (env === 'production' && autoSlug !== 'nguyen-van-a') return 'slug tự sinh production = ' + autoSlug;
  if (!/Địa chỉ công khai sẽ là: https:\/\//.test(prev1)) return 'xem trước địa chỉ sai: ' + prev1;
  if (after !== before) return 'vẫn gọi create_memorial với slug sai vùng';
  if (!/thu-nghiem-|kiem-thu-/.test(msg)) return 'không báo lỗi vùng tên: ' + msg;
  if (JSON.stringify(refs) !== JSON.stringify([want])) return 'gọi Supabase: ' + JSON.stringify(refs);
  if (errors.length) return 'lỗi JS: ' + errors[0];
  return true;
}
await rcase('F1', 'Staging: đăng nhập (giả) → danh sách hồ sơ → slug tự sinh có tiền tố kiem-thu- → chặn slug thiếu tiền tố', () => adminFlow(D.stgAdmin, 'quanly.phyverse.io.vn', 'staging'));
await rcase('F2', 'Production: đăng nhập (giả) → danh sách → slug tự sinh không tiền tố → chặn slug thử', () => adminFlow(D.prdAdmin, 'quanly.phyverse.com.vn', 'production'));

await browser.close();
rmSync(work, { recursive: true, force: true });
let pass = 0;
for (const r of results) { console.log((r.ok ? 'ĐẠT ' : 'LỖI ') + r.id + ' ' + r.desc + (r.ok ? '' : '  ⇒ ' + r.note)); if (r.ok) pass++; }
console.log('TỔNG: ' + pass + '/' + results.length + ' đạt');
process.exit(pass === results.length ? 0 : 1);
