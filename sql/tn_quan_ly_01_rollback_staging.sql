-- =====================================================================
-- TƯỞNG NIỆM SỐ — ROLLBACK QUẢN LÝ 01 (STAGING ONLY)
-- Đích DUY NHẤT: phyverse-staging (fingerprint 7678071634733212629)
-- Gỡ đúng những gì tn_quan_ly_01_staging.sql đã thêm.
-- KHÔNG xóa trang tưởng niệm, quyền grave_managers hay media đã tạo qua giao diện:
-- các dòng đó vẫn còn; chỉ là người quản lý không sửa/tạo được nữa.
-- =====================================================================
begin;
set local lock_timeout = '5s';
do $$ begin
  if (select system_identifier::text from pg_control_system()) is distinct from '7678071634733212629' then
    raise exception 'DUNG: không phải phyverse-staging'; end if;
  if to_regclass('public.memorial_creators') is null then
    raise exception 'DUNG: migration chưa được chạy — không có gì để rollback'; end if;
end $$;

revoke update (deceased_name, saint_name, birth_label, death_label, epigraph, intro, honorific,
               portrait_path, timeline, wishes, footer_note, is_published)
  on table public.graves from authenticated;
drop policy graves_update_mgr on public.graves;
drop policy graves_select_mgr on public.graves;
drop function public.create_memorial(text, text);
alter table public.graves
  drop constraint graves_deceased_name_len,
  drop constraint graves_timeline_max,
  drop constraint graves_wishes_max;
drop table public.memorial_creators;

do $$ begin
  if has_column_privilege('authenticated', 'public.graves', 'deceased_name', 'UPDATE') then
    raise exception 'TU_KIEM: authenticated vẫn sửa được graves'; end if;
  if (select count(*) from pg_policies where schemaname = 'public' and tablename = 'graves') <> 1 then
    raise exception 'TU_KIEM: graves phải còn đúng 1 policy (graves_select_published)'; end if;
end $$;
commit;
