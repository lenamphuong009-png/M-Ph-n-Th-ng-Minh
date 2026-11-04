// Kiểm thử build fail-closed. Chạy: node tests/tn-build-tests.mjs .
// Kiểm thử build: chạy scripts/tn-build.mjs trong bản clone sạch với các tổ hợp biến Netlify giả lập.
// Dùng: node build-tests.mjs <đường-dẫn-repo>
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readdirSync, statSync, readFileSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative } from 'node:path';

const REPO = process.argv[2] || '.';
if (!REPO) { console.error('Thiếu đường dẫn repo'); process.exit(2); }
const STAGING = 'bd773533-d3c1-4c26-86d2-2ea190623ae2';
const BASE = { SITE_ID: STAGING, SITE_NAME: 'phyverse-staging-tn', CONTEXT: 'production', BRANCH: 'engine-v1',
  HEAD: 'engine-v1', PULL_REQUEST: 'false', REVIEW_ID: '', COMMIT_REF: 'abc', TN_DEPLOY_ENV: 'staging', TN_SITE_ROLE: 'admin' };

function freshClone() {
  const d = mkdtempSync(join(tmpdir(), 'tnb-'));
  execFileSync('git', ['clone', '-q', REPO, d]);
  execFileSync('git', ['-C', d, 'checkout', '-q', execFileSync('git', ['-C', REPO, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()]);
  return d;
}
function walk(dir, root = dir) {
  return readdirSync(dir).flatMap(n => { const p = join(dir, n); return statSync(p).isDirectory() ? walk(p, root) : [relative(root, p)]; }).sort();
}
function run(dir, env) {
  const clean = Object.fromEntries(Object.entries(process.env).filter(([k]) => !(k in BASE)));
  const r = spawnSync('sh', ['scripts/tn-build.sh'], { cwd: dir, env: { ...clean, ...env }, encoding: 'utf8' });
  return { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
}
const results = [];
function tcase(id, desc, envPatch, expectPass, prep, check) {
  const d = freshClone();
  try {
    if (prep) prep(d);
    const env = { ...BASE, ...envPatch };
    for (const k of Object.keys(env)) if (env[k] === undefined) delete env[k];
    const r = run(d, env);
    let ok = expectPass ? r.code === 0 : r.code !== 0;
    let note = (r.out.match(/\[tn-build\] (DỪNG|ĐẠT)[^\n]*/) || [''])[0].slice(0, 160);
    if (ok && expectPass && check) { const c = check(d); if (c !== true) { ok = false; note += ' || ' + c; } }
    if (ok && !expectPass) { try { if (walk(join(d, 'dist')).length && /DỪNG/.test(r.out) === false) ok = false; } catch {} }
    results.push({ id, desc, expect: expectPass ? 'CHẠY' : 'TỪ CHỐI', ok, note });
  } finally { rmSync(d, { recursive: true, force: true }); }
}
const commitAll = (d, msg) => { execFileSync('git', ['-C', d, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qam', msg]); };
const EXPECT_ADMIN = ['_headers', 'admin.html', 'index.html', 'tn-build.js', 'vendor/qrcode-generator-2.0.4.js'];

tcase('B1', 'Staging, CONTEXT=production, BRANCH=engine-v1', {}, true, null, d => {
  const files = walk(join(d, 'dist'));
  if (JSON.stringify(files) !== JSON.stringify(EXPECT_ADMIN)) return 'dist sai: ' + files.join(',');
  const tb = readFileSync(join(d, 'dist', 'tn-build.js'), 'utf8');
  if (!/"env":"staging"/.test(tb) || !/"role":"admin"/.test(tb) || !/mhyadympadwxzuwwlnps/.test(tb)) return 'tn-build.js sai';
  const hd = readFileSync(join(d, 'dist', '_headers'), 'utf8');
  if (!/X-Robots-Tag: noindex/.test(hd) || !/X-Frame-Options: DENY/.test(hd)) return '_headers sai';
  for (const f of files) { const t = readFileSync(join(d, 'dist', f), 'utf8'); if (/jswnebhtxuvyzmcpruad/.test(t)) return 'có ref production trong ' + f; }
  return true;
});
tcase('B2', 'Deploy Preview trên staging (PULL_REQUEST=true, REVIEW_ID=7)', { CONTEXT: 'deploy-preview', BRANCH: 'pull/7/head', HEAD: 'tn/x', PULL_REQUEST: 'true', REVIEW_ID: '7' }, true);
tcase('B3', 'TN_DEPLOY_ENV=production trên SITE_ID staging', { TN_DEPLOY_ENV: 'production' }, false);
tcase('B4', 'TN_SITE_ROLE=public trên site admin staging', { TN_SITE_ROLE: 'public' }, false);
tcase('B5', 'Thiếu TN_DEPLOY_ENV', { TN_DEPLOY_ENV: undefined }, false);
tcase('B6', 'Thiếu TN_SITE_ROLE', { TN_SITE_ROLE: undefined }, false);
tcase('B7', 'TN_DEPLOY_ENV gõ sai (Staging)', { TN_DEPLOY_ENV: 'Staging' }, false);
tcase('B8', 'SITE_ID lạ (site chưa có trong bảng)', { SITE_ID: '11111111-2222-3333-4444-555555555555' }, false);
tcase('B9', 'Thiếu SITE_ID', { SITE_ID: undefined }, false);
tcase('B10', 'SITE_NAME không khớp bảng', { SITE_NAME: 'glittery-swan-23c695' }, false);
tcase('B11', 'CONTEXT=branch-deploy (engine-v1)', { CONTEXT: 'branch-deploy' }, false);
tcase('B12', 'CONTEXT=production nhưng BRANCH=release-v1', { BRANCH: 'release-v1' }, false);
tcase('B13', 'CONTEXT=production nhưng BRANCH=feature-x', { BRANCH: 'feature-x' }, false);
tcase('B14', 'CONTEXT=production, BRANCH=engine-v1 nhưng PULL_REQUEST=true', { PULL_REQUEST: 'true', REVIEW_ID: '3' }, false);
tcase('B15', 'Deploy Preview nhưng PULL_REQUEST=false', { CONTEXT: 'deploy-preview', PULL_REQUEST: 'false', REVIEW_ID: '7' }, false);
tcase('B16', 'Deploy Preview thiếu REVIEW_ID', { CONTEXT: 'deploy-preview', PULL_REQUEST: 'true', REVIEW_ID: '' }, false);
tcase('B17', 'CONTEXT=dev', { CONTEXT: 'dev' }, false);
tcase('B18', 'CONTEXT trống', { CONTEXT: undefined }, false);
tcase('B19', 'Tệp admin.html bị sửa trong lúc build (khác commit)', {}, false, d => { writeFileSync(join(d, 'admin.html'), readFileSync(join(d, 'admin.html'), 'utf8') + '\n<!-- x -->'); });
tcase('B20', 'Bảng cấu hình thêm tệp sql vào danh sách admin', {}, false, d => {
  const p = join(d, 'scripts/tn-build-config.json'); const c = JSON.parse(readFileSync(p, 'utf8'));
  c.roles.admin.push('sql/tn_quan_ly_03_staging.sql'); writeFileSync(p, JSON.stringify(c)); commitAll(d, 'x'); });
tcase('B21', 'Bảng cấu hình thêm tệp ngoài thư mục (../)', {}, false, d => {
  const p = join(d, 'scripts/tn-build-config.json'); const c = JSON.parse(readFileSync(p, 'utf8'));
  c.roles.admin.push('../secret.js'); writeFileSync(p, JSON.stringify(c)); commitAll(d, 'x'); });
tcase('B22', 'Bảng cấu hình thêm tệp chưa được Git theo dõi', {}, false, d => {
  const p = join(d, 'scripts/tn-build-config.json'); const c = JSON.parse(readFileSync(p, 'utf8'));
  c.roles.admin.push('extra.js'); writeFileSync(p, JSON.stringify(c)); commitAll(d, 'x'); writeFileSync(join(d, 'extra.js'), '1'); });
tcase('B23', 'Thiếu tệp bắt buộc (index.html bị xóa khỏi commit)', {}, false, d => { execFileSync('git', ['-C', d, 'rm', '-q', 'index.html']); commitAll(d, 'x'); });
tcase('B24', 'Publishable key bị thay bằng chuỗi không phải sb_publishable_', {}, false, d => {
  const p = join(d, 'scripts/tn-build-config.json'); const c = JSON.parse(readFileSync(p, 'utf8'));
  c.environments.staging.publishable_key = 'eyJhbGciOiJIUzI1NiJ9.xxx'; writeFileSync(p, JSON.stringify(c)); commitAll(d, 'x'); });
tcase('B25', 'supabase_url không khớp supabase_ref', {}, false, d => {
  const p = join(d, 'scripts/tn-build-config.json'); const c = JSON.parse(readFileSync(p, 'utf8'));
  c.environments.staging.supabase_url = 'https://jswnebhtxuvyzmcpruad.supabase.co'; writeFileSync(p, JSON.stringify(c)); commitAll(d, 'x'); });
tcase('B26', 'Thư mục dist/ bị đưa vào Git', {}, false, d => { mkdirSync(join(d, 'dist')); writeFileSync(join(d, 'dist', 'x.txt'), '1');
  execFileSync('git', ['-C', d, 'add', '-f', 'dist/x.txt']); commitAll(d, 'x'); });
tcase('B27', 'Có dist/ cũ chứa tệp lạ trước khi build — phải bị dọn sạch', {}, true,
  d => { mkdirSync(join(d, 'dist', 'sql'), { recursive: true }); writeFileSync(join(d, 'dist', 'sql', 'old.sql'), 'x'); },
  d => JSON.stringify(walk(join(d, 'dist'))) === JSON.stringify(EXPECT_ADMIN) ? true : 'dist còn tệp cũ');

let pass = 0;
for (const r of results) { console.log((r.ok ? "ĐẠT " : "LỖI ") + r.id + " [" + r.expect + "] " + r.desc + "  ⇒ " + r.note); if (r.ok) pass++; }
console.log('TỔNG: ' + pass + '/' + results.length + ' đạt');
process.exit(pass === results.length ? 0 : 1);
