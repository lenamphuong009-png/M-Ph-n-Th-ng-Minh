-- =====================================================================
-- TƯỞNG NIỆM SỐ — ROLLBACK QUẢN LÝ 03 (STAGING ONLY, fingerprint 7678071634733212629)
-- Trả về đúng định nghĩa trong tn_quan_ly_03_sao_luu_truoc.md.
-- AN TOÀN DỮ LIỆU: script TỰ DỪNG nếu đã có dữ liệu thật của 2 tính năng
--   (lời nhắn, bản ghi âm, tệp audios/, hoặc title/description đã được nhập).
--   Khi đó phải xuất/sao lưu dữ liệu đó trước — KHÔNG rollback mù.
-- =====================================================================
begin;
set local lock_timeout = '5s';
do $$ begin
  if (select system_identifier::text from pg_control_system()) is distinct from '7678071634733212629' then
    raise exception 'DUNG: không phải phyverse-staging'; end if;
  if to_regclass('public.guestbook_entries') is null then
    raise exception 'DUNG: migration 03 chưa chạy'; end if;
  if (select count(*) from public.guestbook_entries) > 0 then
    raise exception 'DUNG: đã có % lời nhắn — sao lưu trước, không rollback tự động', (select count(*) from public.guestbook_entries); end if;
  if exists (select 1 from public.memorial_media where type = 'audio' or title is not null or description is not null or rights_confirmed_at is not null) then
    raise exception 'DUNG: đã có bản ghi âm / tiêu đề / mô tả — sao lưu trước, không rollback tự động'; end if;
  if exists (select 1 from storage.objects where bucket_id = 'memorial-media' and split_part(name, '/', 2) = 'audios') then
    raise exception 'DUNG: còn tệp trong thư mục audios/ — xử lý trước khi rollback'; end if;
end $$;

drop function public.moderate_guestbook_entry(uuid, text);
drop function public.post_guestbook_entry(text, text);
drop table public.guestbook_entries;   -- đã kiểm tra rỗng ở trên

drop policy tn_media_insert on storage.objects;
create policy tn_media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'memorial-media'
    and name ~ '^[0-9a-f-]{36}/(images/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)|videos/[0-9a-f-]{36}\.(mp4|webm|mov))$'
    and public.has_grave_permission(split_part(name, '/', 1)));
update storage.buckets
   set allowed_mime_types = array['image/jpeg','image/png','image/webp','video/mp4','video/webm','video/quicktime']
 where id = 'memorial-media';

revoke update (title, description) on table public.memorial_media from authenticated;
revoke select (title, description) on table public.memorial_media from anon;
drop trigger tn_media_rights_now_trg on public.memorial_media;
drop function public.tn_media_rights_now();

alter table public.memorial_media
  drop constraint mm_audio_required, drop constraint mm_description_len, drop constraint mm_title_len,
  drop constraint mm_path_matches, drop constraint mm_path_format, drop constraint memorial_media_type_check;
alter table public.memorial_media
  add constraint memorial_media_type_check check (type = any (array['image','video'])),
  add constraint mm_path_format check (storage_path ~ '^[0-9a-f-]{36}/(images/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)|videos/[0-9a-f-]{36}\.(mp4|webm|mov))$'),
  add constraint mm_path_matches check (split_part(storage_path, '/', 1) = grave_id::text
        and split_part(storage_path, '/', 2) = case type when 'image' then 'images' else 'videos' end);
alter table public.memorial_media drop column rights_confirmed_at, drop column description, drop column title;

do $$ begin
  if exists (select 1 from pg_attribute where attrelid = 'public.memorial_media'::regclass and attname in ('title','description','rights_confirmed_at') and not attisdropped)
     or to_regclass('public.guestbook_entries') is not null then
    raise exception 'TU_KIEM: rollback chưa sạch'; end if;
  if (select allowed_mime_types::text from storage.buckets where id = 'memorial-media')
     is distinct from '{image/jpeg,image/png,image/webp,video/mp4,video/webm,video/quicktime}' then
    raise exception 'TU_KIEM: bucket chưa về mốc'; end if;
end $$;
commit;
