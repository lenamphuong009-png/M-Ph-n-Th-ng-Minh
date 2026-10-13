# Sao lưu trạng thái staging TRƯỚC migration tn_quan_ly_03

- Project: phyverse-staging `mhyadympadwxzuwwlnps`, fingerprint `7678071634733212629`
- Thời điểm chụp: 2026-10-13T07:55:26Z (14:55 giờ VN)
- Nhánh/commit code tại thời điểm chụp: `engine-v1` @ `dc598ed`

## Mốc dữ liệu (dùng để chứng minh dữ liệu cũ không đổi)

| Mục | Giá trị |
|---|---|
| graves | 5 dòng, md5 `696239e7694ec2ebdd63312453e77360` |
| memorial_media | 6 dòng, md5 `57d37751716b4a7e03eeeb2490f98de3` |
| grave_managers | 2 dòng |
| memorial_creators | 1 dòng |
| storage.objects (memorial-media) | 7 tệp |
| ACL bảng public (rel_acl_md5) | `728220d5f0db0a1c34ba2f55111ad752` |
| ACL hàm public (fn_acl_md5) | `18f438b94da42fe60b7e0b3a04804fc6` |
| Policy khác (ngoài memorial_media / tn_media*) | `369309f5cca48eb00280b220a42437f4` |
| Bucket khác (ngoài memorial-media) | `7ba900d4be302262471834ecd15baf0a` |

## Định nghĩa sẽ bị thay đổi (giá trị gốc để rollback)

### memorial_media — ràng buộc
```
memorial_media_type_check: CHECK ((type = ANY (ARRAY['image'::text, 'video'::text])))
mm_path_format: CHECK ((storage_path ~ '^[0-9a-f-]{36}/(images/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)|videos/[0-9a-f-]{36}\.(mp4|webm|mov))$'::text))
mm_path_matches: CHECK (((split_part(storage_path, '/'::text, 1) = (grave_id)::text) AND (split_part(storage_path, '/'::text, 2) =
CASE type WHEN 'image'::text THEN 'images'::text ELSE 'videos'::text END)))
```
### memorial_media — cột: id, grave_id, type, storage_path, caption, sort_order, created_by, created_at
### memorial_media — quyền
```
table: {postgres=arwdDxtm/postgres,service_role=Dxtm/postgres,authenticated=ard/postgres}
id/grave_id/type/storage_path/created_at = {anon=r/postgres}
caption/sort_order = {authenticated=w/postgres,anon=r/postgres}
```
### Bucket memorial-media
```
public=true, file_size_limit=52428800,
allowed_mime_types={image/jpeg,image/png,image/webp,video/mp4,video/webm,video/quicktime}
```
### Storage policy tn_media_insert (INSERT, authenticated) — WITH CHECK gốc
```
((bucket_id = 'memorial-media'::text) AND (name ~ '^[0-9a-f-]{36}/(images/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)|videos/[0-9a-f-]{36}\.(mp4|webm|mov))$'::text) AND has_grave_permission(split_part(name, '/'::text, 1)))
```
(tn_media_select_mgr, tn_media_delete và 5 policy của memorial_media KHÔNG bị thay đổi.)

### Đối tượng mới (chưa tồn tại trước migration)
guestbook_entries, post_guestbook_entry(text,text), moderate_guestbook_entry(uuid,text)
