-- =====================================================================
-- TƯỞNG NIỆM SỐ — QUẢN LÝ 03: GIỌNG NÓI ĐƯỢC LƯU GIỮ + SỔ LƯU BÚT (STAGING ONLY)
-- Đích DUY NHẤT: phyverse-staging (ref mhyadympadwxzuwwlnps, fingerprint 7678071634733212629)
-- Chỉ BỔ SUNG: không UPDATE/DELETE dòng dữ liệu cũ nào. Tự kiểm md5 dữ liệu cũ trước/sau.
-- Sao lưu định nghĩa gốc: tn_quan_ly_03_sao_luu_truoc.md — Rollback: tn_quan_ly_03_rollback_staging.sql
--
-- A. GIỌNG NÓI: memorial_media nhận thêm type 'audio' (thư mục audios/), cột title/description/
--    rights_confirmed_at; bucket nhận MP3/M4A/WAV/OGG; policy tải lên mở rộng sang audios/
--    — vẫn CHỈ người quản lý đúng trang (has_grave_permission). Khách chỉ đọc (trang đã xuất bản).
-- B. SỔ LƯU BÚT: bảng guestbook_entries. Khách KHÔNG có quyền ghi bảng; chỉ gửi qua hàm
--    post_guestbook_entry (trang đã xuất bản, giới hạn độ dài, chống spam, mặc định CHỜ DUYỆT).
--    Khách chỉ đọc lời nhắn ĐÃ DUYỆT. Người quản lý duyệt/ẩn/xóa qua moderate_guestbook_entry.
-- =====================================================================
begin;
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

commit;
