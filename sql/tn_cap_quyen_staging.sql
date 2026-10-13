-- =====================================================================
-- TƯỞNG NIỆM SỐ — CẤP QUYỀN QUẢN LÝ (STAGING ONLY, fingerprint 7678071634733212629)
-- Thay <<EMAIL>> bằng email tài khoản được chỉ định. Không cấp cho ai khác.
--   Phần A (bắt buộc): cho phép tài khoản TẠO trang mới (memorial_creators).
--      Trang do tài khoản này tạo sẽ tự được cấp quyền quản lý — chỉ trang đó.
--   Phần B (tùy chọn): cho phép quản lý trang có sẵn 'vu-duc-hoa'.
-- Gỡ quyền: delete from public.memorial_creators where user_id = <id>;
--           update public.grave_managers set revoked_at = now() where user_id = <id> and grave_id = <id trang>;
-- =====================================================================
begin;
do $$
declare v_uid uuid; v_n int;
begin
  if (select system_identifier::text from pg_control_system()) is distinct from '7678071634733212629' then
    raise exception 'DUNG: không phải phyverse-staging'; end if;
  select count(*), min(id::text)::uuid into v_n, v_uid from auth.users where lower(email) = lower('<<EMAIL>>');
  if v_n <> 1 then raise exception 'DUNG: tìm thấy % tài khoản với email này (phải đúng 1)', v_n; end if;
  if (select email_confirmed_at is null from auth.users where id = v_uid) then
    raise exception 'DUNG: email chưa được xác nhận'; end if;

  -- Phần A
  insert into public.memorial_creators (user_id, note) values (v_uid, 'Quản lý Tưởng niệm số — staging')
    on conflict (user_id) do nothing;

  -- Phần B (xóa khối này nếu không muốn quản lý trang vu-duc-hoa)
  if not exists (select 1 from public.grave_managers gm join public.graves g on g.id = gm.grave_id
                 where g.memorial_slug = 'vu-duc-hoa' and gm.user_id = v_uid and gm.revoked_at is null) then
    insert into public.grave_managers (grave_id, user_id, role, granted_by, granted_note)
      select g.id, v_uid, 'phyverse_support', null, 'Cấp tay — staging' from public.graves g where g.memorial_slug = 'vu-duc-hoa';
  end if;

  -- TỰ KIỂM: chỉ đúng 1 người được tạo trang, quyền quản lý chỉ của người này
  if (select count(*) from public.memorial_creators) <> 1 then
    raise exception 'TU_KIEM: memorial_creators có % dòng (kỳ vọng 1)', (select count(*) from public.memorial_creators); end if;
  if exists (select 1 from public.grave_managers where user_id <> v_uid and revoked_at is null) then
    raise exception 'TU_KIEM: có tài khoản khác đang có quyền quản lý'; end if;
end $$;
commit;
