-- =====================================================================
-- TƯỞNG NIỆM SỐ — CẤP QUYỀN TẠO TRANG (STAGING ONLY, fingerprint 7678071634733212629)
-- Thay <<EMAIL>> bằng email tài khoản được chỉ định. Không cấp cho ai khác.
-- Chỉ làm MỘT việc: thêm tài khoản vào memorial_creators (được TẠO trang mới).
-- Trang do tài khoản này tạo sẽ tự được cấp quyền quản lý — CHỈ trang đó (qua create_memorial).
-- KHÔNG cấp quyền quản lý trang có sẵn nào (kể cả vu-duc-hoa).
-- Gỡ quyền: delete from public.memorial_creators where user_id = '<id>';
-- =====================================================================
begin;
do $$
declare v_uid uuid; v_n int;
begin
  if (select system_identifier::text from pg_control_system()) is distinct from '7678071634733212629' then
    raise exception 'DUNG: không phải phyverse-staging'; end if;
  if to_regclass('public.memorial_creators') is null then
    raise exception 'DUNG: chưa có memorial_creators (migration tn_quan_ly_01 chưa chạy)'; end if;
  if (select count(*) from public.memorial_creators) <> 0 or (select count(*) from public.grave_managers) <> 0 then
    raise exception 'DUNG: memorial_creators/grave_managers không còn trống như mốc — kiểm tra trước khi cấp'; end if;

  select count(*) into v_n from auth.users where lower(email) = lower('<<EMAIL>>');
  if v_n <> 1 then raise exception 'DUNG: tìm thấy % tài khoản với email này (phải đúng 1)', v_n; end if;
  select id into v_uid from auth.users where lower(email) = lower('<<EMAIL>>');
  if (select email_confirmed_at is null from auth.users where id = v_uid) then
    raise exception 'DUNG: email chưa được xác nhận'; end if;

  insert into public.memorial_creators (user_id, note) values (v_uid, 'Quản lý Tưởng niệm số — staging');

  -- TỰ KIỂM (sai → hủy toàn bộ)
  if (select count(*) from public.memorial_creators) <> 1
     or not exists (select 1 from public.memorial_creators where user_id = v_uid) then
    raise exception 'TU_KIEM: memorial_creators phải có đúng 1 dòng là tài khoản được chỉ định'; end if;
  if (select count(*) from public.grave_managers) <> 0 then
    raise exception 'TU_KIEM: grave_managers phải vẫn trống (không cấp quyền trang nào)'; end if;
end $$;
commit;
