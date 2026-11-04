// =====================================================================
// tn-build.mjs — Đóng gói Memorial Engine cho Netlify theo nguyên tắc FAIL-CLOSED
//
// 1. Xác định site bằng SITE_ID (biến chỉ-đọc Netlify cấp) → tra bảng scripts/tn-build-config.json
// 2. Đối chiếu TN_DEPLOY_ENV / TN_SITE_ROLE (đặt trên từng site) với bảng — lệch là DỪNG
// 3. Chỉ chấp nhận đúng CONTEXT/BRANCH được liệt kê cho site đó — còn lại DỪNG
// 4. Tạo dist/ MỚI, chỉ chép các tệp trong danh sách của vai trò (tệp phải được Git theo dõi, không bị sửa)
// 5. Sinh dist/tn-build.js (chỉ cấu hình của ĐÚNG 1 môi trường) và dist/_headers
// 6. Kiểm tra lại dist/: đúng danh sách tệp, đúng mã băm, đọc lại tn-build.js
// Bất kỳ bước nào sai → thoát mã khác 0, Netlify không xuất bản gì (bản đang chạy giữ nguyên).
// Chỉ dùng thư viện có sẵn của Node. Không in khóa ra log.
// =====================================================================
import { readFileSync, writeFileSync, mkdirSync, rmSync, readdirSync, statSync, copyFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const DIST = join(ROOT, 'dist');
const CONFIG_PATH = join(ROOT, 'scripts', 'tn-build-config.json');
const ENV_NAMES = ['staging', 'production'];
const ROLE_NAMES = ['admin', 'public'];
const GENERATED = ['tn-build.js', '_headers'];

function fail(msg) {
  console.error('[tn-build] DỪNG: ' + msg);
  process.exit(1);
}
function log(msg) { console.log('[tn-build] ' + msg); }
function sha256(path) { return createHash('sha256').update(readFileSync(path)).digest('hex'); }
function git(args) {
  return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}
function listFiles(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) out.push(...listFiles(p));
    else out.push(relative(DIST, p).split(sep).join('/'));
  }
  return out.sort();
}

// ---------- 0. Đọc biến môi trường build ----------
const E = process.env;
const v = {
  SITE_ID: E.SITE_ID || '', SITE_NAME: E.SITE_NAME || '', CONTEXT: E.CONTEXT || '',
  BRANCH: E.BRANCH || '', HEAD: E.HEAD || '', PULL_REQUEST: E.PULL_REQUEST || '',
  REVIEW_ID: E.REVIEW_ID || '', COMMIT_REF: E.COMMIT_REF || '',
  TN_DEPLOY_ENV: E.TN_DEPLOY_ENV || '', TN_SITE_ROLE: E.TN_SITE_ROLE || ''
};
// Ghi lại giá trị thực tế (không có bí mật) để đối chiếu hành vi Netlify
log('Biến build: ' + Object.entries(v).map(([k, x]) => k + '=' + (x === '' ? '(trống)' : x)).join(' | '));

// ---------- 1. Bảng cấu hình ----------
let cfg;
try { cfg = JSON.parse(readFileSync(CONFIG_PATH, 'utf8')); } catch (e) { fail('không đọc được scripts/tn-build-config.json: ' + e.message); }
if (cfg.version !== 1) fail('phiên bản bảng cấu hình không hỗ trợ');
if (!cfg.sites || !cfg.environments || !cfg.roles) fail('bảng cấu hình thiếu sites/environments/roles');

// ---------- 2. Site + môi trường + vai trò ----------
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v.SITE_ID)) fail('SITE_ID trống hoặc sai định dạng');
const site = Object.prototype.hasOwnProperty.call(cfg.sites, v.SITE_ID) ? cfg.sites[v.SITE_ID] : null;
if (!site) fail('SITE_ID ' + v.SITE_ID + ' không có trong bảng cho phép');
if (!ENV_NAMES.includes(site.env) || !ROLE_NAMES.includes(site.role)) fail('bảng cấu hình ghi môi trường/vai trò không hợp lệ cho site này');
if (!ENV_NAMES.includes(v.TN_DEPLOY_ENV)) fail('TN_DEPLOY_ENV trống hoặc không hợp lệ (cần staging | production)');
if (!ROLE_NAMES.includes(v.TN_SITE_ROLE)) fail('TN_SITE_ROLE trống hoặc không hợp lệ (cần admin | public)');
if (v.TN_DEPLOY_ENV !== site.env) fail('TN_DEPLOY_ENV=' + v.TN_DEPLOY_ENV + ' không khớp site (' + site.env + ')');
if (v.TN_SITE_ROLE !== site.role) fail('TN_SITE_ROLE=' + v.TN_SITE_ROLE + ' không khớp site (' + site.role + ')');
if (site.site_name && v.SITE_NAME && v.SITE_NAME !== site.site_name) fail('SITE_NAME=' + v.SITE_NAME + ' không khớp bảng (' + site.site_name + ')');

// ---------- 3. CONTEXT / BRANCH ----------
const rules = Array.isArray(site.allow) ? site.allow : [];
const ok = rules.some(function (r) {
  if (r.context !== v.CONTEXT) return false;
  if (r.context === 'production') return typeof r.branch === 'string' && v.BRANCH === r.branch && v.PULL_REQUEST !== 'true';
  if (r.context === 'deploy-preview') return v.PULL_REQUEST === 'true' && /^[1-9][0-9]{0,6}$/.test(v.REVIEW_ID);
  return false; // branch-deploy, dev và mọi loại khác: KHÔNG BAO GIỜ được phép
});
if (!ok) fail('CONTEXT=' + v.CONTEXT + ' / BRANCH=' + v.BRANCH + ' / PULL_REQUEST=' + v.PULL_REQUEST + ' không được phép cho site ' + (site.site_name || v.SITE_ID));

// ---------- 4. Cấu hình môi trường (chỉ 1 môi trường) ----------
const envCfg = cfg.environments[site.env];
if (!envCfg) fail('bảng cấu hình chưa có môi trường ' + site.env);
if (!/^[a-z0-9]{20}$/.test(envCfg.supabase_ref || '')) fail('supabase_ref sai định dạng');
if (envCfg.supabase_url !== 'https://' + envCfg.supabase_ref + '.supabase.co') fail('supabase_url không khớp supabase_ref');
if (!/^sb_publishable_[A-Za-z0-9_-]{10,}$/.test(envCfg.publishable_key || '')) fail('publishable_key không phải khóa công khai sb_publishable_');

// ---------- 5. Danh sách tệp của vai trò ----------
const files = cfg.roles[site.role];
if (!Array.isArray(files) || files.length === 0) fail('vai trò ' + site.role + ' không có danh sách tệp');
for (const f of files) {
  if (typeof f !== 'string' || !/^[a-z0-9][a-z0-9._/-]*\.(html|js)$/.test(f) || f.includes('..') || f.startsWith('/')) fail('tên tệp không được phép trong danh sách: ' + f);
  if (GENERATED.includes(f)) fail('tệp ' + f + ' là tệp sinh tự động, không được có trong danh sách');
}
let tracked;
try { tracked = new Set(git(['ls-files', '-z']).split('\0').filter(Boolean)); } catch (e) { fail('không chạy được git ls-files: ' + e.message); }
for (const f of files) {
  if (!tracked.has(f)) fail('tệp ' + f + ' không được Git theo dõi');
  try { git(['diff', '--quiet', 'HEAD', '--', f]); } catch (e) { fail('tệp ' + f + ' khác bản trong commit đang build'); }
}

// ---------- 6. Tạo dist/ mới ----------
if (tracked.has('dist') || [...tracked].some(function (t) { return t.startsWith('dist/'); })) fail('thư mục dist/ không được có trong Git');
rmSync(DIST, { recursive: true, force: true });
mkdirSync(DIST, { recursive: true });
const expectHash = {};
for (const f of files) {
  const src = join(ROOT, f), dst = join(DIST, f);
  if (!existsSync(src)) fail('thiếu tệp bắt buộc ' + f);
  mkdirSync(dirname(dst), { recursive: true });
  copyFileSync(src, dst);
  expectHash[f] = sha256(src);
}

// tn-build.js — chỉ chứa cấu hình của đúng 1 môi trường + vai trò
const build = {
  env: site.env, role: site.role,
  supabaseUrl: envCfg.supabase_url, publishableKey: envCfg.publishable_key,
  siteId: v.SITE_ID, context: v.CONTEXT, commit: (v.COMMIT_REF || '').slice(0, 40)
};
const buildJs = '/* Sinh tự động bởi scripts/tn-build.mjs — KHÔNG sửa tay. */\n' +
  'window.TN_BUILD = Object.freeze(' + JSON.stringify(build) + ');\n';
writeFileSync(join(DIST, 'tn-build.js'), buildJs);

// _headers — trang quản trị không được lập chỉ mục, không cho nhúng khung; tn-build.js không lưu đệm lâu
const headers = [
  '/*',
  '  X-Frame-Options: DENY',
  '  X-Content-Type-Options: nosniff',
  '  Referrer-Policy: strict-origin-when-cross-origin'
];
if (site.role === 'admin') headers.push('  X-Robots-Tag: noindex, nofollow');
headers.push('/tn-build.js', '  Cache-Control: no-cache');
writeFileSync(join(DIST, '_headers'), headers.join('\n') + '\n');

// ---------- 7. Kiểm tra kết quả ----------
const expected = [...files, ...GENERATED].sort();
const actual = listFiles(DIST);
if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  fail('dist/ không đúng danh sách. Mong đợi: ' + expected.join(', ') + ' — Thực tế: ' + actual.join(', '));
}
for (const f of files) {
  if (sha256(join(DIST, f)) !== expectHash[f]) fail('mã băm ' + f + ' trong dist/ khác bản gốc');
}
// Đọc lại tn-build.js và kiểm tra
const reread = readFileSync(join(DIST, 'tn-build.js'), 'utf8');
const m = reread.match(/^window\.TN_BUILD = Object\.freeze\((\{.*\})\);$/m);
if (!m) fail('tn-build.js sinh ra sai định dạng');
const back = JSON.parse(m[1]);
if (back.env !== site.env || back.role !== site.role || back.supabaseUrl !== envCfg.supabase_url) fail('tn-build.js đọc lại không khớp');
// Không được chứa cấu hình của môi trường khác
for (const [name, other] of Object.entries(cfg.environments)) {
  if (name === site.env) continue;
  for (const f of actual) {
    const txt = readFileSync(join(DIST, f), 'utf8');
    if (txt.includes(other.supabase_ref) || txt.includes(other.publishable_key)) fail('dist/' + f + ' chứa cấu hình của môi trường ' + name);
  }
}
// Lớp phụ: chuỗi trông giống khóa bí mật
for (const f of actual) {
  const txt = readFileSync(join(DIST, f), 'utf8');
  if (/sb_secret_|service_role"\s*:|eyJhbGciOi[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/.test(txt)) fail('dist/' + f + ' có chuỗi giống khóa bí mật');
}

log('ĐẠT: ' + site.env + '/' + site.role + ' — site ' + (site.site_name || v.SITE_ID) + ' — CONTEXT ' + v.CONTEXT +
    ' — ' + actual.length + ' tệp: ' + actual.join(', '));
