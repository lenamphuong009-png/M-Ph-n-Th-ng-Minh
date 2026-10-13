-- =====================================================================
-- TƯỞNG NIỆM SỐ — QUẢN LÝ 01 (STAGING ONLY)
-- Đích DUY NHẤT: phyverse-staging (ref mhyadympadwxzuwwlnps, fingerprint 7678071634733212629)
-- Bổ sung tối thiểu để người quản lý tự tạo/sửa/xuất bản trang tưởng niệm:
--   1. memorial_creators: danh sách tài khoản được TẠO trang mới.
--   2. create_memorial(slug, tên): tạo trang ở trạng thái NHÁP và tự cấp quyền
--      quản lý trang đó cho người tạo (grave_managers, role phyverse_support).
--   3. graves: người quản lý ĐỌC được bản nháp của trang mình và SỬA đúng các
--      cột nội dung (không sửa slug, không sửa số nén hương).
--   4. Giới hạn độ dài tên, số mục dòng thời gian / di nguyện.
-- Không xóa, không đổi dữ liệu có sẵn. Không đụng module Quỹ, không đụng bucket khác.
-- Rollback: tn_quan_ly_01_rollback_staging.sql
-- =====================================================================
begin;
set local lock_timeout = '5s';

do $$ begin
  if (select system_identifier::text from pg_control_system()) is distinct from '7678071634733212629' then
    raise exception 'DUNG: không phải phyverse-staging'; end if;
  if current_user <> 'postgres' then
    raise exception 'DUNG: current_user = %, phải là postgres', current_user; end if;
  if to_regclass('public.graves') is null or to_regclass('public.grave_managers') is null
     or to_regclass('public.memorial_media') is null or to_regclass('public.quy_coi_nguon') is null then
    raise exception 'DUNG: cấu trúc không khớp staging'; end if;
  if to_regclass('public.memorial_creators') is not null
     or to_regprocedure('public.create_memorial(text,text)') is not null then
    raise exception 'DUNG: migration này đã được chạy'; end if;
end $$;

-- 1. Ai được tạo trang mới
create table public.memorial_creators (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  granted_at timestamptz not null default now(),
  note       text check (note is null or char_length(note) <= 200)
);
alter table public.memorial_creators enable row level security;
revoke all on table public.memorial_creators from public, anon, authenticated;
grant select on table public.memorial_creators to authenticated;
create policy mc_select_own on public.memorial_creators
  for select to authenticated using (user_id = (select auth.uid()));

-- 2. Giới hạn nội dung (dữ liệu hiện có đều thỏa)
alter table public.graves
  add constraint graves_deceased_name_len check (char_length(btrim(deceased_name)) between 1 and 200),
  add constraint graves_timeline_max check (jsonb_array_length(timeline) <= 50),
  add constraint graves_wishes_max   check (jsonb_array_length(wishes) <= 20);

-- 3. Người quản lý: đọc bản nháp + sửa cột nội dung của đúng trang mình
create policy graves_select_mgr on public.graves
  for select to authenticated using (public.has_grave_permission(id::text));
create policy graves_update_mgr on public.graves
  for update to authenticated
  using (public.has_grave_permission(id::text))
  with check (public.has_grave_permission(id::text));
grant update (deceased_name, saint_name, birth_label, death_label, epigraph, intro, honorific,
              portrait_path, timeline, wishes, footer_note, is_published)
  on table public.graves to authenticated;

-- 4. Tạo trang mới (luôn là NHÁP) + cấp quyền quản lý cho người tạo
create function public.create_memorial(p_slug text, p_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if v_uid is null or not exists (select 1 from public.memorial_creators where user_id = v_uid) then
    raise exception 'Tài khoản không có quyền tạo trang tưởng niệm' using errcode = '42501';
  end if;
  insert into public.graves (memorial_slug, deceased_name, is_published)
    values (p_slug, btrim(p_name), false)
    returning id into v_id;
  insert into public.grave_managers (grave_id, user_id, role, granted_by, granted_note)
    values (v_id, v_uid, 'phyverse_support', v_uid, 'Tự cấp khi tạo trang (create_memorial)');
  return v_id;
end
$fn$;
revoke all on function public.create_memorial(text, text) from public, anon;
grant execute on function public.create_memorial(text, text) to authenticated;

-- TỰ KIỂM
do $$ begin
  if not (select relrowsecurity from pg_class where oid = 'public.memorial_creators'::regclass) then
    raise exception 'TU_KIEM: memorial_creators chưa bật RLS'; end if;
  if has_table_privilege('anon', 'public.memorial_creators', 'SELECT')
     or has_table_privilege('authenticated', 'public.memorial_creators', 'INSERT')
     or has_table_privilege('authenticated', 'public.memorial_creators', 'UPDATE')
     or has_table_privilege('authenticated', 'public.memorial_creators', 'DELETE') then
    raise exception 'TU_KIEM: quyền memorial_creators sai'; end if;
  if has_function_privilege('anon', 'public.create_memorial(text,text)', 'EXECUTE') then
    raise exception 'TU_KIEM: anon gọi được create_memorial'; end if;
  if not has_function_privilege('authenticated', 'public.create_memorial(text,text)', 'EXECUTE') then
    raise exception 'TU_KIEM: authenticated không gọi được create_memorial'; end if;
  if has_column_privilege('authenticated', 'public.graves', 'memorial_slug', 'UPDATE')
     or has_column_privilege('authenticated', 'public.graves', 'incense_count', 'UPDATE')
     or has_column_privilege('anon', 'public.graves', 'deceased_name', 'UPDATE')
     or has_table_privilege('authenticated', 'public.graves', 'INSERT')
     or has_table_privilege('authenticated', 'public.graves', 'DELETE') then
    raise exception 'TU_KIEM: quyền graves vượt phạm vi'; end if;
  if not has_column_privilege('authenticated', 'public.graves', 'is_published', 'UPDATE') then
    raise exception 'TU_KIEM: thiếu quyền sửa is_published'; end if;
end $$;

commit;
