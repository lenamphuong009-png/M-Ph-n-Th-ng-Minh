-- =====================================================================
-- TƯỞNG NIỆM SỐ — CHẠY THỬ 2 tn_quan_ly_03: MIGRATION + BÀI THỬ HÀNH VI (STAGING ONLY)
-- Đích DUY NHẤT: phyverse-staging (ref mhyadympadwxzuwwlnps, fingerprint 7678071634733212629)
--
-- CÁCH HOẠT ĐỘNG
--   1. Mở MỘT transaction (begin). File này KHÔNG có lệnh commit.
--   2. Chạy NGUYÊN VĂN thân migration tn_quan_ly_03_staging.sql (sao bằng chương trình, không sửa).
--   3. Tạo dữ liệu GIẢ (4 tài khoản *.invalid, 4 trang 'zz-dr2-*', lời nhắn và metadata tệp giả).
--      KHÔNG dùng dữ liệu thật. KHÔNG tải tệp thật (chỉ thêm dòng metadata trong bảng storage.objects).
--   4. Chạy 76 bài thử (G01–G31, M01–M19, A01–A23, P01–P03) với đúng vai (khách / người quản lý / người lạ / người bị thu hồi quyền),
--      ghi lại kết quả THỰC TẾ của từng bài (mã lỗi hoặc giá trị trả về).
--   5. Kết thúc bằng lỗi chủ động → PostgreSQL HỦY TOÀN BỘ (migration + dữ liệu giả + mọi thay đổi):
--        'DRYRUN2_OK: ...'   → mọi bài thử SQL đều PASS
--        'DRYRUN2_FAIL: ...' → có bài FAIL (bảng kết quả đi kèm ngay trong thông báo)
--      Bất kỳ lỗi nào khác (VD 'DUNG: ...', 'TU_KIEM: ...', lỗi cú pháp) → cũng đã bị hủy toàn bộ;
--      gửi lại nguyên văn để phân tích.
--   Trong MỌI trường hợp, staging không thay đổi. Sau khi chạy, đối chiếu lại bằng truy vấn chỉ đọc.
--
-- PHẠM VI: chỉ kiểm được những gì SQL kiểm được. Các mục U01–U05 (Data API thật, Storage API thật,
-- tải tệp thật...) được liệt kê là UNVERIFIED trong thông báo kết quả — không được coi là đã đạt.
-- =====================================================================
begin;

-- =====================================================================
-- PHẦN 1 — THÂN MIGRATION (nguyên văn từ tn_quan_ly_03_staging.sql, từ sau "begin;" tới trước "commit;")
-- =====================================================================
set local lock_timeout = '5s';

-- ---------- PRE ----------
do $$ begin
  if (select system_identifier::text from pg_control_system()) is distinct from '7678071634733212629' then
    raise exception 'DUNG: không phải phyverse-staging'; end if;
  if current_user <> 'postgres' then raise exception 'DUNG: current_user = %', current_user; end if;
  if to_regclass('public.memorial_creators') is null then
    raise exception 'DUNG: thiếu migration tn_quan_ly_01'; end if;
  if to_regclass('public.guestbook_entries') is not null
     or to_regprocedure('public.post_guestbook_entry(text,text)') is not null
     or exists (select 1 from pg_attribute where attrelid = 'public.memorial_media'::regclass and attname = 'title') then
    raise exception 'DUNG: migration 03 đã chạy (một phần hoặc toàn bộ)'; end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conname = 'memorial_media_type_check')
     is distinct from 'CHECK ((type = ANY (ARRAY[''image''::text, ''video''::text])))' then
    raise exception 'DUNG: memorial_media_type_check khác bản sao lưu'; end if;
  if (select md5(string_agg(row_to_json(g)::text, ';' order by g.id)) from public.graves g)
     is distinct from '696239e7694ec2ebdd63312453e77360' then
    raise exception 'DUNG: dữ liệu graves đã thay đổi so với lúc sao lưu — chụp lại mốc trước khi chạy'; end if;
  if (select md5(string_agg(row_to_json(m)::text, ';' order by m.id)) from public.memorial_media m)
     is distinct from '57d37751716b4a7e03eeeb2490f98de3' then
    raise exception 'DUNG: dữ liệu memorial_media đã thay đổi so với lúc sao lưu'; end if;
end $$;

-- =========================== A. GIỌNG NÓI ===========================
alter table public.memorial_media
  add column title text,
  add column description text,
  add column rights_confirmed_at timestamptz;

alter table public.memorial_media drop constraint memorial_media_type_check;
alter table public.memorial_media drop constraint mm_path_format;
alter table public.memorial_media drop constraint mm_path_matches;
alter table public.memorial_media
  add constraint memorial_media_type_check check (type = any (array['image','video','audio'])),
  add constraint mm_path_format check (storage_path ~ '^[0-9a-f-]{36}/(images/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)|videos/[0-9a-f-]{36}\.(mp4|webm|mov)|audios/[0-9a-f-]{36}\.(mp3|m4a|wav|ogg))$'),
  add constraint mm_path_matches check (split_part(storage_path, '/', 1) = grave_id::text
        and split_part(storage_path, '/', 2) = case type when 'image' then 'images' when 'video' then 'videos' when 'audio' then 'audios' end),
  add constraint mm_title_len check (title is null or char_length(title) <= 150),
  add constraint mm_description_len check (description is null or char_length(description) <= 500),
  add constraint mm_audio_required check (type <> 'audio' or (btrim(coalesce(title, '')) <> '' and rights_confirmed_at is not null));

-- Thời điểm xác nhận quyền luôn lấy giờ máy chủ (không tin giờ trình duyệt gửi lên)
create function public.tn_media_rights_now()
returns trigger language plpgsql set search_path = public, pg_temp as $fn$
begin
  if new.rights_confirmed_at is not null then new.rights_confirmed_at := now(); end if;
  return new;
end $fn$;
revoke all on function public.tn_media_rights_now() from public, anon, authenticated;
create trigger tn_media_rights_now_trg before insert on public.memorial_media
  for each row execute function public.tn_media_rights_now();

grant select (title, description) on table public.memorial_media to anon;
grant update (title, description) on table public.memorial_media to authenticated;

update storage.buckets
   set allowed_mime_types = array['image/jpeg','image/png','image/webp','video/mp4','video/webm','video/quicktime',
                                  'audio/mpeg','audio/mp3','audio/mp4','audio/x-m4a','audio/m4a','audio/aac',
                                  'audio/wav','audio/x-wav','audio/wave','audio/vnd.wave','audio/ogg']
 where id = 'memorial-media';

drop policy tn_media_insert on storage.objects;
create policy tn_media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'memorial-media'
    and name ~ '^[0-9a-f-]{36}/(images/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)|videos/[0-9a-f-]{36}\.(mp4|webm|mov)|audios/[0-9a-f-]{36}\.(mp3|m4a|wav|ogg))$'
    and public.has_grave_permission(split_part(name, '/', 1)));

-- =========================== B. SỔ LƯU BÚT ===========================
create table public.guestbook_entries (
  id          uuid primary key default gen_random_uuid(),
  grave_id    uuid not null references public.graves(id) on delete restrict,
  message     text not null check (char_length(btrim(message)) between 1 and 1000),
  status      text not null default 'pending' check (status in ('pending', 'approved', 'hidden')),
  created_at  timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  client_hash text   -- băm (IP + trang) chỉ để chống spam; không ai ngoài hệ thống đọc được cột này
);
create index guestbook_entries_grave_created on public.guestbook_entries (grave_id, created_at desc);
alter table public.guestbook_entries enable row level security;
revoke all on table public.guestbook_entries from public, anon, authenticated;
grant select (id, grave_id, message, created_at) on table public.guestbook_entries to anon;
grant select (id, grave_id, message, status, created_at, reviewed_at) on table public.guestbook_entries to authenticated;
create policy gb_select_approved on public.guestbook_entries for select to anon, authenticated
  using (status = 'approved' and exists (select 1 from public.graves g where g.id = guestbook_entries.grave_id and g.is_published = true));
create policy gb_select_mgr on public.guestbook_entries for select to authenticated
  using (public.has_grave_permission(grave_id::text));
-- KHÔNG có policy/quyền INSERT, UPDATE, DELETE cho anon/authenticated: mọi thay đổi đi qua 2 hàm dưới.

create function public.post_guestbook_entry(p_slug text, p_message text)
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare
  v_grave uuid;
  v_msg   text := btrim(coalesce(p_message, ''));
  v_ip    text;
  v_hash  text;
begin
  select id into v_grave from public.graves where memorial_slug = p_slug and is_published = true;
  if v_grave is null then raise exception 'GB_NOT_FOUND: trang không tồn tại hoặc chưa xuất bản'; end if;
  if char_length(v_msg) < 1 then raise exception 'GB_EMPTY: lời nhắn trống'; end if;
  if char_length(v_msg) > 1000 then raise exception 'GB_TOO_LONG: lời nhắn quá 1000 ký tự'; end if;

  -- IP người gửi (chỉ để băm chống spam). Ưu tiên header do hạ tầng đặt (khó giả mạo hơn),
  -- cuối cùng mới dùng x-forwarded-for. Giới hạn theo trang (30/10 phút) là lớp chặn cứng.
  begin
    v_ip := coalesce(nullif(current_setting('request.headers', true)::json ->> 'cf-connecting-ip', ''),
                     nullif(current_setting('request.headers', true)::json ->> 'x-real-ip', ''),
                     split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1));
  exception when others then v_ip := '';
  end;
  v_hash := case when btrim(v_ip) <> '' then md5(btrim(v_ip) || '|' || v_grave::text || '|tn-guestbook') end;

  if v_hash is not null and (select count(*) from public.guestbook_entries
       where client_hash = v_hash and created_at > now() - interval '10 minutes') >= 3 then
    raise exception 'GB_RATE_LIMIT: gửi quá nhanh'; end if;
  if (select count(*) from public.guestbook_entries
       where grave_id = v_grave and created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'GB_RATE_LIMIT: trang đang nhận quá nhiều lời nhắn'; end if;
  if (select count(*) from public.guestbook_entries where grave_id = v_grave and status = 'pending') >= 300 then
    raise exception 'GB_QUEUE_FULL: hàng chờ duyệt đã đầy'; end if;
  if exists (select 1 from public.guestbook_entries where grave_id = v_grave
               and lower(message) = lower(v_msg) and created_at > now() - interval '24 hours') then
    raise exception 'GB_DUPLICATE: lời nhắn trùng'; end if;

  insert into public.guestbook_entries (grave_id, message, client_hash) values (v_grave, v_msg, v_hash);
  return 'pending';
end
$fn$;
revoke all on function public.post_guestbook_entry(text, text) from public;
grant execute on function public.post_guestbook_entry(text, text) to anon, authenticated;

create function public.moderate_guestbook_entry(p_id uuid, p_action text)
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare v_grave uuid;
begin
  select grave_id into v_grave from public.guestbook_entries where id = p_id;
  if v_grave is null or not public.has_grave_permission(v_grave::text) then
    raise exception 'Không có quyền với lời nhắn này' using errcode = '42501'; end if;
  if p_action = 'approve' then
    update public.guestbook_entries set status = 'approved', reviewed_at = now(), reviewed_by = auth.uid() where id = p_id;
    return 'approved';
  elsif p_action = 'hide' then
    update public.guestbook_entries set status = 'hidden', reviewed_at = now(), reviewed_by = auth.uid() where id = p_id;
    return 'hidden';
  elsif p_action = 'delete' then
    delete from public.guestbook_entries where id = p_id;
    return 'deleted';
  end if;
  raise exception 'GB_BAD_ACTION: thao tác không hợp lệ';
end
$fn$;
revoke all on function public.moderate_guestbook_entry(uuid, text) from public, anon;
grant execute on function public.moderate_guestbook_entry(uuid, text) to authenticated;

-- ---------- TỰ KIỂM ----------
do $$ begin
  -- dữ liệu cũ không đổi (so trên đúng các cột cũ)
  if (select md5(string_agg(row_to_json(g)::text, ';' order by g.id)) from public.graves g)
     is distinct from '696239e7694ec2ebdd63312453e77360' then raise exception 'TU_KIEM: graves bị thay đổi'; end if;
  if (select md5(string_agg(row_to_json(x)::text, ';' order by x.id)) from
        (select m.id, m.grave_id, m.type, m.storage_path, m.caption, m.sort_order, m.created_by, m.created_at from public.memorial_media m) x)
     is distinct from '57d37751716b4a7e03eeeb2490f98de3' then raise exception 'TU_KIEM: memorial_media bị thay đổi'; end if;
  -- quyền
  if has_table_privilege('anon', 'public.guestbook_entries', 'INSERT') or has_table_privilege('anon', 'public.guestbook_entries', 'UPDATE')
     or has_table_privilege('anon', 'public.guestbook_entries', 'DELETE') or has_table_privilege('authenticated', 'public.guestbook_entries', 'INSERT')
     or has_any_column_privilege('authenticated', 'public.guestbook_entries', 'UPDATE') or has_table_privilege('authenticated', 'public.guestbook_entries', 'DELETE')
     or has_column_privilege('anon', 'public.guestbook_entries', 'client_hash', 'SELECT')
     or has_column_privilege('authenticated', 'public.guestbook_entries', 'client_hash', 'SELECT')
     or has_column_privilege('anon', 'public.guestbook_entries', 'status', 'SELECT') then
    raise exception 'TU_KIEM: quyền guestbook_entries vượt phạm vi'; end if;
  if not has_function_privilege('anon', 'public.post_guestbook_entry(text,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.moderate_guestbook_entry(uuid,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.tn_media_rights_now()', 'EXECUTE') then
    raise exception 'TU_KIEM: quyền hàm sai'; end if;
  if has_column_privilege('authenticated', 'public.memorial_media', 'rights_confirmed_at', 'UPDATE')
     or has_table_privilege('anon', 'public.memorial_media', 'INSERT') then
    raise exception 'TU_KIEM: quyền memorial_media vượt phạm vi'; end if;
  if (select count(*) from pg_policies where schemaname = 'storage' and policyname like 'tn_media%') <> 3 then
    raise exception 'TU_KIEM: số policy storage tn_media khác 3'; end if;
end $$;

-- ===== HẾT PHẦN 1 =====

-- =====================================================================
-- PHẦN 2 — BÀI THỬ HÀNH VI (chạy sau migration, cùng transaction)
-- Dữ liệu giả: 4 tài khoản *.invalid, 4 trang 'zz-dr2-*', lời nhắn/tệp giả — KHÔNG dùng dữ liệu thật.
-- Mô phỏng vai trò như PostgREST: SET LOCAL ROLE anon|authenticated + request.jwt.claims (+ request.headers cho IP).
-- Mỗi bài: chạy câu lệnh dưới đúng vai, bắt mã lỗi thực tế, so với kết quả mong đợi.
-- =====================================================================
do $dr2$
declare
  t record; actual text; st text; msg text; b boolean; ok boolean;
  res text := ''; n_pass int := 0; n_fail int := 0;
begin
  if (select system_identifier::text from pg_control_system()) is distinct from '7678071634733212629' then
    raise exception 'DUNG: không phải phyverse-staging'; end if;

  -- ---------- DỮ LIỆU GIẢ (chạy với quyền postgres, chỉ tồn tại trong transaction này) ----------
  insert into auth.users (id, aud, role, email, email_confirmed_at, created_at, updated_at) values
    ('a0000000-0000-4000-8000-0000000000a1', 'authenticated', 'authenticated', 'dr2-quanly-a@example.invalid', now(), now(), now()),
    ('a0000000-0000-4000-8000-0000000000b1', 'authenticated', 'authenticated', 'dr2-quanly-b@example.invalid', now(), now(), now()),
    ('a0000000-0000-4000-8000-0000000000c1', 'authenticated', 'authenticated', 'dr2-nguoi-la-c@example.invalid', now(), now(), now()),
    ('a0000000-0000-4000-8000-0000000000d1', 'authenticated', 'authenticated', 'dr2-da-thu-hoi-d@example.invalid', now(), now(), now());
  insert into public.graves (id, memorial_slug, deceased_name, is_published) values
    ('d0000000-0000-4000-8000-000000000001', 'zz-dr2-pub',  'DR2 Trang công khai', true),
    ('d0000000-0000-4000-8000-000000000002', 'zz-dr2-nhap', 'DR2 Trang nháp',      false),
    ('d0000000-0000-4000-8000-000000000003', 'zz-dr2-b',    'DR2 Trang của B',     true),
    ('d0000000-0000-4000-8000-000000000004', 'zz-dr2-q',    'DR2 Hàng chờ đầy',    true);
  insert into public.grave_managers (grave_id, user_id, role, revoked_at) values
    ('d0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-0000000000a1', 'family_manager', null),
    ('d0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-0000000000a1', 'family_manager', null),
    ('d0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-0000000000b1', 'family_manager', null),
    ('d0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-0000000000d1', 'family_manager', now());  -- D đã bị thu hồi
  insert into public.guestbook_entries (id, grave_id, message, status, created_at) values
    ('f0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001', 'Lời nhắn mẫu 1', 'pending',  now() - interval '2 days'),
    ('f0000000-0000-4000-8000-000000000002', 'd0000000-0000-4000-8000-000000000003', 'Lời nhắn mẫu 2', 'pending',  now() - interval '2 days'),
    ('f0000000-0000-4000-8000-000000000003', 'd0000000-0000-4000-8000-000000000001', 'Lời nhắn mẫu 3', 'pending',  now() - interval '2 days'),
    ('f0000000-0000-4000-8000-000000000004', 'd0000000-0000-4000-8000-000000000002', 'Lời nhắn mẫu 4', 'approved', now() - interval '2 days');
  insert into public.guestbook_entries (grave_id, message, status, created_at)
    select 'd0000000-0000-4000-8000-000000000004', 'Lời nhắn rác ' || i, 'pending', now() - interval '2 days' from generate_series(1, 300) i;
  -- tệp giả trong bảng storage.objects (KHÔNG có tệp thật; chỉ để trigger kiểm tra tồn tại)
  insert into storage.objects (bucket_id, name, owner_id) values
    ('memorial-media', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000002.mp3', 'a0000000-0000-4000-8000-0000000000a1'),
    ('memorial-media', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000003.m4a', 'a0000000-0000-4000-8000-0000000000a1'),
    ('memorial-media', 'd0000000-0000-4000-8000-000000000001/images/e0000000-0000-4000-8000-000000000004.jpg', 'a0000000-0000-4000-8000-0000000000a1'),
    ('memorial-media', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000005.flac', 'a0000000-0000-4000-8000-0000000000a1'),
    ('memorial-media', 'd0000000-0000-4000-8000-000000000003/audios/e0000000-0000-4000-8000-000000000006.mp3', 'a0000000-0000-4000-8000-0000000000b1'),
    ('memorial-media', 'd0000000-0000-4000-8000-000000000002/audios/e0000000-0000-4000-8000-000000000007.ogg', 'a0000000-0000-4000-8000-0000000000a1');

  -- ---------- DANH SÁCH BÀI THỬ ----------
  -- vai: anon | A (quản lý zz-dr2-pub & zz-dr2-nhap) | B (quản lý zz-dr2-b) | C (đăng nhập, không quyền) | D (quyền đã thu hồi) | postgres (kiểm tra trạng thái)
  -- mong_doi: OK = chạy không lỗi | TRUE = câu lệnh trả true | mã SQLSTATE (VD 42501) | MSG:<chuỗi> = lỗi có chứa chuỗi
  for t in select * from (values
    -- ===== G: post_guestbook_entry =====
    (1,  'G01', 'Khách gửi lời nhắn hợp lệ (có khoảng trắng 2 đầu) cho trang đã xuất bản', 'anon', '203.0.113.1',
         $q$select public.post_guestbook_entry('zz-dr2-pub', '  Kính viếng ông  ')$q$, 'OK'),
    (2,  'G02', 'Lời nhắn G01 được lưu đúng trang, đã cắt khoảng trắng, trạng thái pending, chưa duyệt', 'postgres', null,
         $q$select count(*) = 1 from public.guestbook_entries where grave_id = 'd0000000-0000-4000-8000-000000000001' and message = 'Kính viếng ông' and status = 'pending' and reviewed_at is null and reviewed_by is null$q$, 'TRUE'),
    (3,  'G03', 'Hàm trả về đúng chữ pending', 'anon', '203.0.113.11',
         $q$select public.post_guestbook_entry('zz-dr2-pub', 'Thắp nén nhang') = 'pending'$q$, 'TRUE'),
    (4,  'G04', 'Nội dung chỉ có khoảng trắng → từ chối', 'anon', '203.0.113.12',
         $q$select public.post_guestbook_entry('zz-dr2-pub', '     ')$q$, 'MSG:GB_EMPTY'),
    (5,  'G05', 'Nội dung NULL → từ chối', 'anon', '203.0.113.13',
         $q$select public.post_guestbook_entry('zz-dr2-pub', null)$q$, 'MSG:GB_EMPTY'),
    (6,  'G06', 'Nội dung 1001 ký tự → từ chối', 'anon', '203.0.113.14',
         $q$select public.post_guestbook_entry('zz-dr2-pub', repeat('a', 1001))$q$, 'MSG:GB_TOO_LONG'),
    (7,  'G07', 'Nội dung đúng 1000 ký tự (biên) → nhận', 'anon', '203.0.113.15',
         $q$select public.post_guestbook_entry('zz-dr2-pub', repeat('b', 1000))$q$, 'OK'),
    (8,  'G08', 'Trang nháp → từ chối (cùng thông báo với trang không tồn tại)', 'anon', '203.0.113.16',
         $q$select public.post_guestbook_entry('zz-dr2-nhap', 'Gửi vào trang nháp')$q$, 'MSG:GB_NOT_FOUND'),
    (9,  'G09', 'Trang không tồn tại → từ chối', 'anon', '203.0.113.17',
         $q$select public.post_guestbook_entry('zz-dr2-khong-co', 'Gửi vào trang không có')$q$, 'MSG:GB_NOT_FOUND'),
    (10, 'G10', 'Trùng nội dung trong 24h (khác hoa/thường, khác IP) → từ chối', 'anon', '203.0.113.18',
         $q$select public.post_guestbook_entry('zz-dr2-pub', 'KÍNH VIẾNG ÔNG')$q$, 'MSG:GB_DUPLICATE'),
    (11, 'G11', 'Cùng 1 IP: lần 1/3 trong 10 phút → nhận', 'anon', '203.0.113.50',
         $q$select public.post_guestbook_entry('zz-dr2-pub', 'Người gửi X lần 1')$q$, 'OK'),
    (12, 'G12', 'Cùng 1 IP: lần 2/3 → nhận', 'anon', '203.0.113.50',
         $q$select public.post_guestbook_entry('zz-dr2-pub', 'Người gửi X lần 2')$q$, 'OK'),
    (13, 'G13', 'Cùng 1 IP: lần 3/3 → nhận', 'anon', '203.0.113.50',
         $q$select public.post_guestbook_entry('zz-dr2-pub', 'Người gửi X lần 3')$q$, 'OK'),
    (14, 'G14', 'Cùng 1 IP: lần 4 trong 10 phút → từ chối (ngưỡng 3)', 'anon', '203.0.113.50',
         $q$select public.post_guestbook_entry('zz-dr2-pub', 'Người gửi X lần 4')$q$, 'MSG:gửi quá nhanh'),
    (15, 'G15', 'Cùng IP đó nhưng trang khác → nhận (giới hạn tính theo từng trang)', 'anon', '203.0.113.50',
         $q$select public.post_guestbook_entry('zz-dr2-b', 'Người gửi X ở trang B')$q$, 'OK'),
    (16, 'G16', 'Không có header IP: 29 lời nhắn liên tiếp vào trang B → nhận đủ 29 (tổng 30 trong 10 phút)', 'anon', null,
         $q$select count(*) = 29 from (select public.post_guestbook_entry('zz-dr2-b', 'Lời nhắn hàng loạt ' || i) r from generate_series(1, 29) i) x where r = 'pending'$q$, 'TRUE'),
    (17, 'G17', 'Lời nhắn thứ 31 vào trang B trong 10 phút (IP mới) → từ chối (ngưỡng 30/trang)', 'anon', '203.0.113.77',
         $q$select public.post_guestbook_entry('zz-dr2-b', 'Lời nhắn thứ 31')$q$, 'MSG:quá nhiều lời nhắn'),
    (18, 'G18', 'Trang có 300 lời nhắn chờ duyệt → từ chối (hàng chờ đầy)', 'anon', '203.0.113.90',
         $q$select public.post_guestbook_entry('zz-dr2-q', 'Gửi khi hàng chờ đầy')$q$, 'MSG:GB_QUEUE_FULL'),
    (19, 'G19', 'Lời nhắn có IP được lưu dạng băm (không lưu IP gốc)', 'postgres', null,
         $q$select count(*) = 3 and bool_and(client_hash ~ '^[0-9a-f]{32}$') and bool_and(client_hash not like '%203.0.113.50%') from public.guestbook_entries where message like 'Người gửi X lần %'$q$, 'TRUE'),
    (20, 'G20', 'Khách INSERT thẳng vào bảng → bị chặn', 'anon', null,
         $q$insert into public.guestbook_entries (grave_id, message, status) values ('d0000000-0000-4000-8000-000000000001', 'Ghi thẳng', 'approved')$q$, '42501'),
    (21, 'G21', 'Khách UPDATE (tự duyệt) → bị chặn', 'anon', null,
         $q$update public.guestbook_entries set status = 'approved'$q$, '42501'),
    (22, 'G22', 'Khách DELETE → bị chặn', 'anon', null,
         $q$delete from public.guestbook_entries$q$, '42501'),
    (23, 'G23', 'Khách đọc cột status → bị chặn', 'anon', null,
         $q$select status from public.guestbook_entries limit 1$q$, '42501'),
    (24, 'G24', 'Khách đọc cột client_hash → bị chặn', 'anon', null,
         $q$select client_hash from public.guestbook_entries limit 1$q$, '42501'),
    (25, 'G25', 'Khách không thấy lời nhắn chờ duyệt của trang công khai', 'anon', null,
         $q$select count(*) = 0 from public.guestbook_entries where grave_id = 'd0000000-0000-4000-8000-000000000001'$q$, 'TRUE'),
    (26, 'G26', 'Khách không thấy lời nhắn ĐÃ DUYỆT nhưng thuộc trang NHÁP', 'anon', null,
         $q$select count(*) = 0 from public.guestbook_entries where id = 'f0000000-0000-4000-8000-000000000004'$q$, 'TRUE'),
    (27, 'G27', 'Người đăng nhập không quyền (C) cũng không thấy lời nhắn chờ duyệt', 'C', null,
         $q$select count(*) = 0 from public.guestbook_entries where status = 'pending' or grave_id in ('d0000000-0000-4000-8000-000000000001','d0000000-0000-4000-8000-000000000003','d0000000-0000-4000-8000-000000000004')$q$, 'TRUE'),
    (28, 'G28', 'Người quản lý A thấy lời nhắn chờ duyệt của trang mình', 'A', null,
         $q$select count(*) >= 3 from public.guestbook_entries where grave_id = 'd0000000-0000-4000-8000-000000000001' and status = 'pending'$q$, 'TRUE'),
    (29, 'G29', 'Người quản lý A không thấy lời nhắn chờ duyệt của trang B', 'A', null,
         $q$select count(*) = 0 from public.guestbook_entries where grave_id = 'd0000000-0000-4000-8000-000000000003'$q$, 'TRUE'),
    (30, 'G30', 'Người quản lý A UPDATE thẳng bảng → bị chặn (chỉ được qua hàm)', 'A', null,
         $q$update public.guestbook_entries set status = 'approved' where id = 'f0000000-0000-4000-8000-000000000001'$q$, '42501'),
    (31, 'G31', 'Người quản lý A INSERT thẳng bảng → bị chặn', 'A', null,
         $q$insert into public.guestbook_entries (grave_id, message) values ('d0000000-0000-4000-8000-000000000001', 'Ghi thẳng')$q$, '42501'),
    -- ===== M: moderate_guestbook_entry =====
    (40, 'M01', 'Khách gọi hàm duyệt → bị chặn (không có quyền EXECUTE)', 'anon', null,
         $q$select public.moderate_guestbook_entry('f0000000-0000-4000-8000-000000000001', 'approve')$q$, '42501'),
    (41, 'M02', 'Người lạ C duyệt lời nhắn trang A (biết ID) → bị từ chối', 'C', null,
         $q$select public.moderate_guestbook_entry('f0000000-0000-4000-8000-000000000001', 'approve')$q$, '42501'),
    (42, 'M03', 'Người có quyền đã bị THU HỒI (D) duyệt → bị từ chối', 'D', null,
         $q$select public.moderate_guestbook_entry('f0000000-0000-4000-8000-000000000001', 'approve')$q$, '42501'),
    (43, 'M04', 'Sau M01–M03: lời nhắn vẫn pending, chưa ai duyệt', 'postgres', null,
         $q$select status = 'pending' and reviewed_by is null from public.guestbook_entries where id = 'f0000000-0000-4000-8000-000000000001'$q$, 'TRUE'),
    (44, 'M05', 'Quản lý A duyệt lời nhắn của trang mình → được', 'A', null,
         $q$select public.moderate_guestbook_entry('f0000000-0000-4000-8000-000000000001', 'approve') = 'approved'$q$, 'TRUE'),
    (45, 'M06', 'Sau M05: approved, reviewed_by = A, có thời điểm duyệt', 'postgres', null,
         $q$select status = 'approved' and reviewed_by = 'a0000000-0000-4000-8000-0000000000a1' and reviewed_at is not null from public.guestbook_entries where id = 'f0000000-0000-4000-8000-000000000001'$q$, 'TRUE'),
    (46, 'M07', 'Khách giờ thấy lời nhắn đã duyệt (trang đã xuất bản)', 'anon', null,
         $q$select count(*) = 1 from public.guestbook_entries where id = 'f0000000-0000-4000-8000-000000000001' and message = 'Lời nhắn mẫu 1'$q$, 'TRUE'),
    (47, 'M08', 'Quản lý A ẩn lời nhắn → được', 'A', null,
         $q$select public.moderate_guestbook_entry('f0000000-0000-4000-8000-000000000001', 'hide') = 'hidden'$q$, 'TRUE'),
    (48, 'M09', 'Sau khi ẩn: khách không thấy nữa', 'anon', null,
         $q$select count(*) = 0 from public.guestbook_entries where id = 'f0000000-0000-4000-8000-000000000001'$q$, 'TRUE'),
    (49, 'M10', 'Quản lý A duyệt lời nhắn của trang B bằng cách thay ID → bị từ chối', 'A', null,
         $q$select public.moderate_guestbook_entry('f0000000-0000-4000-8000-000000000002', 'approve')$q$, '42501'),
    (50, 'M11', 'Quản lý A xóa lời nhắn của trang B bằng cách thay ID → bị từ chối', 'A', null,
         $q$select public.moderate_guestbook_entry('f0000000-0000-4000-8000-000000000002', 'delete')$q$, '42501'),
    (51, 'M12', 'Sau M10–M11: lời nhắn trang B còn nguyên, vẫn pending', 'postgres', null,
         $q$select count(*) = 1 from public.guestbook_entries where id = 'f0000000-0000-4000-8000-000000000002' and status = 'pending' and reviewed_by is null$q$, 'TRUE'),
    (52, 'M13', 'Đối chứng: quản lý B duyệt lời nhắn trang B → được', 'B', null,
         $q$select public.moderate_guestbook_entry('f0000000-0000-4000-8000-000000000002', 'approve') = 'approved'$q$, 'TRUE'),
    (53, 'M14', 'Người lạ C xóa lời nhắn trang B → bị từ chối, lời nhắn còn', 'C', null,
         $q$select public.moderate_guestbook_entry('f0000000-0000-4000-8000-000000000002', 'delete')$q$, '42501'),
    (54, 'M15', 'Sau M14: lời nhắn trang B vẫn còn', 'postgres', null,
         $q$select count(*) = 1 from public.guestbook_entries where id = 'f0000000-0000-4000-8000-000000000002'$q$, 'TRUE'),
    (55, 'M16', 'Thao tác không hợp lệ trên lời nhắn của mình → bị từ chối', 'A', null,
         $q$select public.moderate_guestbook_entry('f0000000-0000-4000-8000-000000000003', 'xoa-het')$q$, 'MSG:GB_BAD_ACTION'),
    (56, 'M17', 'ID không tồn tại → bị từ chối như không có quyền (không lộ thông tin)', 'A', null,
         $q$select public.moderate_guestbook_entry('f0000000-0000-4000-8000-0000000000ff', 'approve')$q$, '42501'),
    (57, 'M18', 'Quản lý A xóa lời nhắn của trang mình → được', 'A', null,
         $q$select public.moderate_guestbook_entry('f0000000-0000-4000-8000-000000000003', 'delete') = 'deleted'$q$, 'TRUE'),
    (58, 'M19', 'Sau M18: lời nhắn đã bị xóa', 'postgres', null,
         $q$select count(*) = 0 from public.guestbook_entries where id = 'f0000000-0000-4000-8000-000000000003'$q$, 'TRUE'),
    -- ===== A: ghi âm (memorial_media + policy Storage + trigger) =====
    (70, 'A01', 'Quản lý A thêm tệp (metadata) .mp3 vào audios/ của trang mình → policy Storage cho phép', 'A', null,
         $q$insert into storage.objects (bucket_id, name, owner_id) values ('memorial-media', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000001.mp3', 'a0000000-0000-4000-8000-0000000000a1')$q$, 'OK'),
    (71, 'A02', 'Quản lý A thêm tệp vào audios/ của trang B → policy Storage chặn', 'A', null,
         $q$insert into storage.objects (bucket_id, name, owner_id) values ('memorial-media', 'd0000000-0000-4000-8000-000000000003/audios/e0000000-0000-4000-8000-000000000011.mp3', 'a0000000-0000-4000-8000-0000000000a1')$q$, '42501'),
    (72, 'A03', 'Quản lý A thêm tệp đuôi .flac (không hỗ trợ) → policy Storage chặn', 'A', null,
         $q$insert into storage.objects (bucket_id, name, owner_id) values ('memorial-media', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000012.flac', 'a0000000-0000-4000-8000-0000000000a1')$q$, '42501'),
    (73, 'A04', 'Khách thêm tệp vào bucket → policy Storage chặn', 'anon', null,
         $q$insert into storage.objects (bucket_id, name) values ('memorial-media', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000013.mp3')$q$, '42501'),
    (74, 'A05', 'Quản lý A thêm bản ghi âm hợp lệ, gửi kèm giờ xác nhận GIẢ 2000-01-01 → được', 'A', null,
         $q$insert into public.memorial_media (grave_id, type, storage_path, title, description, rights_confirmed_at, sort_order) values ('d0000000-0000-4000-8000-000000000001', 'audio', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000001.mp3', 'Lời dặn dò', 'Ghi năm 2015', '2000-01-01T00:00:00Z', 1)$q$, 'OK'),
    (75, 'A06', 'Trigger đã thay giờ xác nhận bằng giờ máy chủ; created_by = A', 'postgres', null,
         $q$select rights_confirmed_at = now() and rights_confirmed_at > '2001-01-01' and created_by = 'a0000000-0000-4000-8000-0000000000a1' and title = 'Lời dặn dò' from public.memorial_media where storage_path = 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000001.mp3'$q$, 'TRUE'),
    (76, 'A07', 'Bản ghi âm thiếu tiêu đề → bị chặn', 'A', null,
         $q$insert into public.memorial_media (grave_id, type, storage_path, rights_confirmed_at) values ('d0000000-0000-4000-8000-000000000001', 'audio', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000002.mp3', now())$q$, '23514'),
    (77, 'A08', 'Bản ghi âm tiêu đề chỉ có khoảng trắng → bị chặn', 'A', null,
         $q$insert into public.memorial_media (grave_id, type, storage_path, title, rights_confirmed_at) values ('d0000000-0000-4000-8000-000000000001', 'audio', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000002.mp3', '   ', now())$q$, '23514'),
    (78, 'A09', 'Bản ghi âm thiếu xác nhận quyền sử dụng → bị chặn', 'A', null,
         $q$insert into public.memorial_media (grave_id, type, storage_path, title) values ('d0000000-0000-4000-8000-000000000001', 'audio', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000003.m4a', 'Không xác nhận')$q$, '23514'),
    (79, 'A10', 'Bản ghi âm nhưng đường dẫn nằm trong images/ → bị chặn', 'A', null,
         $q$insert into public.memorial_media (grave_id, type, storage_path, title, rights_confirmed_at) values ('d0000000-0000-4000-8000-000000000001', 'audio', 'd0000000-0000-4000-8000-000000000001/images/e0000000-0000-4000-8000-000000000004.jpg', 'Sai thư mục', now())$q$, '23514'),
    (80, 'A11', 'Bản ghi âm đuôi .flac → bị chặn', 'A', null,
         $q$insert into public.memorial_media (grave_id, type, storage_path, title, rights_confirmed_at) values ('d0000000-0000-4000-8000-000000000001', 'audio', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000005.flac', 'Sai đuôi', now())$q$, '23514'),
    (81, 'A12', 'Quản lý A thêm bản ghi âm cho trang B → bị chặn (RLS)', 'A', null,
         $q$insert into public.memorial_media (grave_id, type, storage_path, title, rights_confirmed_at) values ('d0000000-0000-4000-8000-000000000003', 'audio', 'd0000000-0000-4000-8000-000000000003/audios/e0000000-0000-4000-8000-000000000006.mp3', 'Trang người khác', now())$q$, '42501'),
    (82, 'A13', 'Bản ghi âm trỏ tới tệp chưa có trong Storage → bị chặn (trigger)', 'A', null,
         $q$insert into public.memorial_media (grave_id, type, storage_path, title, rights_confirmed_at) values ('d0000000-0000-4000-8000-000000000001', 'audio', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000099.mp3', 'Không có tệp', now())$q$, 'MSG:chưa có file'),
    (83, 'A14', 'Bản ghi âm .m4a hợp lệ → được (kiểm tra đuôi m4a)', 'A', null,
         $q$insert into public.memorial_media (grave_id, type, storage_path, title, rights_confirmed_at, sort_order) values ('d0000000-0000-4000-8000-000000000001', 'audio', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000003.m4a', 'Bản m4a', now(), 2)$q$, 'OK'),
    (84, 'A15', 'Khách thêm bản ghi âm → bị chặn', 'anon', null,
         $q$insert into public.memorial_media (grave_id, type, storage_path, title, rights_confirmed_at) values ('d0000000-0000-4000-8000-000000000001', 'audio', 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000002.mp3', 'Khách', now())$q$, '42501'),
    (85, 'A16', 'Khách đọc được tiêu đề + mô tả bản ghi âm của trang đã xuất bản', 'anon', null,
         $q$select count(*) = 1 from public.memorial_media where storage_path = 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000001.mp3' and title = 'Lời dặn dò' and description = 'Ghi năm 2015'$q$, 'TRUE'),
    (86, 'A17', 'Quản lý A thêm bản ghi âm .ogg cho trang NHÁP của mình → được', 'A', null,
         $q$insert into public.memorial_media (grave_id, type, storage_path, title, rights_confirmed_at) values ('d0000000-0000-4000-8000-000000000002', 'audio', 'd0000000-0000-4000-8000-000000000002/audios/e0000000-0000-4000-8000-000000000007.ogg', 'Bản nháp', now())$q$, 'OK'),
    (87, 'A18', 'Khách KHÔNG thấy bản ghi âm của trang nháp', 'anon', null,
         $q$select count(*) = 0 from public.memorial_media where grave_id = 'd0000000-0000-4000-8000-000000000002'$q$, 'TRUE'),
    (88, 'A19', 'Quản lý A sửa giờ xác nhận quyền → bị chặn', 'A', null,
         $q$update public.memorial_media set rights_confirmed_at = '2000-01-01' where storage_path = 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000001.mp3'$q$, '42501'),
    (89, 'A20', 'Quản lý A sửa tiêu đề + mô tả bản ghi âm của mình → được', 'A', null,
         $q$update public.memorial_media set title = 'Lời dặn dò (sửa)', description = 'Mô tả mới' where storage_path = 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000001.mp3'$q$, 'OK'),
    (90, 'A21', 'Sau A20: tiêu đề/mô tả đã đổi, giờ xác nhận không đổi', 'postgres', null,
         $q$select title = 'Lời dặn dò (sửa)' and description = 'Mô tả mới' and rights_confirmed_at = now() from public.memorial_media where storage_path = 'd0000000-0000-4000-8000-000000000001/audios/e0000000-0000-4000-8000-000000000001.mp3'$q$, 'TRUE'),
    (91, 'A22', 'Người lạ C sửa tiêu đề bản ghi âm của A → không đổi được dòng nào', 'C', null,
         $q$with u as (update public.memorial_media set title = 'C sửa' where storage_path like 'd0000000-0000-4000-8000-000000000001/audios/%' returning 1) select count(*) = 0 from u$q$, 'TRUE'),
    (92, 'A23', 'Cấu hình bucket có đủ kiểu âm thanh MP3/M4A/WAV/OGG (CHỈ kiểm cấu hình, không kiểm Storage API)', 'postgres', null,
         $q$select allowed_mime_types @> array['audio/mpeg','audio/mp4','audio/x-m4a','audio/wav','audio/ogg'] and file_size_limit = 52428800 from storage.buckets where id = 'memorial-media'$q$, 'TRUE'),
    -- ===== P: bảo vệ dữ liệu thật =====
    (95, 'P01', 'Dữ liệu thật: 5 trang không đổi (md5 mốc)', 'postgres', null,
         $q$select md5(string_agg(row_to_json(g)::text, ';' order by g.id)) = '696239e7694ec2ebdd63312453e77360' from public.graves g where g.memorial_slug not like 'zz-dr2-%'$q$, 'TRUE'),
    (96, 'P02', 'Dữ liệu thật: 6 ảnh không đổi (md5 mốc, cột cũ)', 'postgres', null,
         $q$select md5(string_agg(row_to_json(x)::text, ';' order by x.id)) = '57d37751716b4a7e03eeeb2490f98de3' from (select m.id, m.grave_id, m.type, m.storage_path, m.caption, m.sort_order, m.created_by, m.created_at from public.memorial_media m where m.grave_id::text not like 'd0000000-%') x$q$, 'TRUE'),
    (97, 'P03', 'Dữ liệu thật: 7 tệp Storage, 2 quyền quản lý, 1 người tạo trang', 'postgres', null,
         $q$select (select count(*) from storage.objects where bucket_id = 'memorial-media' and name not like 'd0000000-%') = 7 and (select count(*) from public.grave_managers where grave_id::text not like 'd0000000-%') = 2 and (select count(*) from public.memorial_creators) = 1$q$, 'TRUE')
  ) v(ord, id, mo_ta, vai, ip, sql, mong_doi) order by ord
  loop
    -- Ngữ cảnh giống PostgREST: claims + headers, rồi đổi vai
    perform set_config('request.jwt.claims', case t.vai
        when 'anon' then '{"role":"anon"}'
        when 'A' then '{"role":"authenticated","sub":"a0000000-0000-4000-8000-0000000000a1"}'
        when 'B' then '{"role":"authenticated","sub":"a0000000-0000-4000-8000-0000000000b1"}'
        when 'C' then '{"role":"authenticated","sub":"a0000000-0000-4000-8000-0000000000c1"}'
        when 'D' then '{"role":"authenticated","sub":"a0000000-0000-4000-8000-0000000000d1"}'
        else '' end, true);
    perform set_config('request.headers', case when t.ip is null then '{}' else json_build_object('x-forwarded-for', t.ip)::text end, true);
    if t.vai = 'anon' then execute 'set local role anon';
    elsif t.vai in ('A','B','C','D') then execute 'set local role authenticated';
    end if;
    begin
      if t.mong_doi = 'TRUE' then
        execute t.sql into b; actual := coalesce(b::text, 'null');
      else
        execute t.sql; actual := 'OK';
      end if;
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      actual := st || ' ' || left(msg, 80);
    end;
    execute 'reset role';
    ok := case
      when t.mong_doi = 'TRUE' then actual = 'true'
      when t.mong_doi = 'OK' then actual = 'OK'
      when t.mong_doi like 'MSG:%' then position(substr(t.mong_doi, 5) in actual) > 0
      else actual like t.mong_doi || ' %' end;
    if ok then n_pass := n_pass + 1; else n_fail := n_fail + 1; end if;
    res := res || format(E'%s | %s | %s | mong đợi: %s | thực tế: %s | %s\n',
                         t.id, t.vai, t.mo_ta, t.mong_doi, actual, case when ok then 'PASS' else 'FAIL' end);
  end loop;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.headers', '', true);

  res := res || E'\nUNVERIFIED (SQL không kiểm được — phải thử sau khi triển khai staging):\n'
             || E'U01 | Data API thật có đặt đúng vai anon/authenticated và chuyển header IP (cf-connecting-ip/x-real-ip/x-forwarded-for) vào hàm không\n'
             || E'U02 | Storage API thật có chặn kiểu tệp (MIME) không thuộc danh sách và tệp > 50MB không\n'
             || E'U03 | Tải tệp âm thanh thật lên Storage, phát lại được sau khi tải lại trang\n'
             || E'U04 | Giới hạn 20MB cho ghi âm (chỉ có ở giao diện, máy chủ giới hạn 50MB)\n'
             || E'U05 | Nhiều yêu cầu đồng thời có thể vượt ngưỡng đếm một chút (không khóa khi đếm)\n';

  if n_fail > 0 then
    raise exception E'DRYRUN2_FAIL: % bài FAIL / % bài PASS — TOÀN BỘ ĐÃ BỊ HỦY, staging không đổi\n%', n_fail, n_pass, res;
  end if;
  raise exception E'DRYRUN2_OK: % / % bài thử SQL đều PASS — TOÀN BỘ ĐÃ BỊ HỦY (rollback), staging không đổi\n%', n_pass, n_pass, res;
end $dr2$;
