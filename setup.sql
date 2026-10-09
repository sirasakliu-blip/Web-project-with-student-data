-- ============================================================
-- setup.sql  วิทยาการคำนวณ ว21032 (ป.3) โรงเรียนบ้านหนองงูเห่าหางกระดิ่ง : คอร์สแวร์ AR
-- รันทั้งไฟล์ใน Supabase > SQL Editor (สำหรับโปรเจกต์ใหม่)
-- แก้ก่อนรัน (ถ้าจำเป็น): บรรทัดที่มี <<แก้>> = โดเมนอีเมลสมมติ และจำนวนหลักของเลขประจำตัวนักเรียน
-- รันซ้ำได้ (ไม่ลบข้อมูลผู้เรียน) ไฟล์นี้มีเฉลยข้อสอบ ห้ามนำไปวางบนเว็บสาธารณะ
-- ============================================================

-- ---------- 1) ตาราง ----------
create table if not exists public.teachers (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table if not exists public.students (
  id text primary key check (id ~ '^[0-9]{5}$'),            -- เลขประจำตัวนักเรียน 5 หลัก <<แก้>> ถ้าโรงเรียนใช้จำนวนหลักอื่น (ต้องแก้ใน handle_new_user และ CFG.idLen ใน HTML ด้วย)
  title text, first_name text not null, last_name text not null, section text,
  user_id uuid unique references auth.users(id) on delete set null,
  photo_path text
);

create table if not exists public.attempts (
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('pre','post')),
  score int not null check (score between 0 and 10),
  answers jsonb,
  created_at timestamptz not null default now(),
  unique (user_id, kind)                                    -- ทำได้ครั้งเดียวต่อชุด
);
alter table public.attempts add column if not exists form text check (form in ('A','B'));  -- ชุดข้อสอบที่ใช้ (A/B)

-- เฉลยและเหตุผลของข้อสอบ: ผู้เรียนอ่านตรง ๆ ไม่ได้ (เปิด RLS และไม่มีนโยบาย) เข้าถึงผ่านฟังก์ชันด้านล่างเท่านั้น
create table if not exists public.test_keys (
  form text not null check (form in ('A','B')),
  q int not null check (q between 1 and 10),
  ans int not null check (ans between 0 and 3),             -- ลำดับตัวเลือกที่ถูก เริ่มนับที่ 0
  why text not null,
  primary key (form, q)
);

create table if not exists public.progress (
  user_id uuid not null references auth.users(id) on delete cascade,
  unit int not null check (unit between 1 and 5),
  done boolean not null default false,
  primary key (user_id, unit)
);

create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  unit int not null check (unit between 1 and 5),
  kind text not null check (kind in ('link','file')),
  url text, storage_path text, note text,
  score numeric check (score between 0 and 10),
  teacher_comment text,
  created_at timestamptz not null default now(),
  check (
    (kind='link' and url ~ '^https://[^ ]+$' and storage_path is null) or
    (kind='file' and storage_path like user_id::text || '/%' and url is null)
  )
);

create table if not exists public.materials (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  kind text not null check (kind in ('file','link','video')),
  url text, storage_path text, file_name text,
  created_at timestamptz not null default now(),
  check (
    (kind='file' and storage_path is not null and url is null) or
    (kind in ('link','video') and url ~ '^https://[^ ]+$' and storage_path is null)
  )
);

-- ---------- 2) ฟังก์ชันสิทธิ์ (security definer + search_path ว่าง) ----------
create or replace function public.is_teacher() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.teachers where user_id = auth.uid());
$$;
create or replace function public.is_student() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.students where user_id = auth.uid());
$$;
create or replace function public.is_member() returns boolean   -- ผู้สอนหรือผู้เรียนที่ลงทะเบียนแล้ว
language sql stable security definer set search_path = '' as $$
  select public.is_teacher() or public.is_student();
$$;

-- ---------- 3) trigger ผูกบัญชีกับรายชื่อ ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.email ~ '^[0-9]{5}@' then                           -- <<แก้>> อีเมลขึ้นต้นด้วยเลข 5 หลัก = ผู้เรียน (ต้องตรงกับ id ในตาราง students)
    if lower(split_part(new.email,'@',2)) <> 'school.ac.th' then   -- <<แก้>> ให้ตรงกับ CFG.domain ใน HTML
      raise exception 'โดเมนอีเมลไม่ถูกต้อง';
    end if;
    update public.students set user_id = new.id
      where id = substr(new.email,1,5) and user_id is null;
    if not found then
      raise exception 'เลขประจำตัวไม่อยู่ในรายชื่อ หรือถูกใช้สมัครแล้ว';
    end if;
  end if;                                                    -- อื่นๆ (ผู้สอน) ข้าม
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 4) เฉลย + ฟังก์ชันแบบทดสอบ ----------
-- ข้อสอบคู่ขนานชุด A/B ข้อความข้อสอบอยู่ใน courseware.html (TEST) ลำดับตัวเลือกต้องตรงกัน
insert into public.test_keys (form, q, ans, why) values
  ('A',1,1,'AR คือการเห็นภาพเสมือนซ้อนอยู่กับโลกจริง ไม่ใช่การดูโทรทัศน์หรือการพิมพ์ภาพ และไม่ได้ทำให้มองไม่เห็นห้องจริงเหมือน VR'),
  ('A',2,3,'VR แทนที่สิ่งที่เห็นด้วยโลกเสมือน ส่วน AR เพิ่มภาพเสมือนเข้าไปในโลกจริง'),
  ('A',3,0,'AR ต้องใช้อุปกรณ์ที่มีกล้องและหน้าจอ เช่น มือถือหรือแท็บเล็ตที่รองรับ'),
  ('A',4,2,'AR ช่วยให้เห็นภาพเสมือนสามมิติซ้อนกับสิ่งที่อยู่ตรงหน้า เช่น โมเดลหัวใจจากภาพในหนังสือ'),
  ('A',5,1,'ภาพหรือ QR code เป็นตัวกระตุ้น ทำให้ระบบรู้ว่าต้องแสดงโมเดลตรงนั้น'),
  ('A',6,3,'ขณะใช้ AR ต้องระวังสิ่งรอบตัว ไม่เดินหรือวิ่งขณะมองหน้าจอ และไม่ถ่ายภาพผู้อื่นโดยไม่ขออนุญาต'),
  ('A',7,0,'ต้องเปิดหน้าเว็บก่อนจึงมีปุ่ม AR แล้วจึงอนุญาตกล้องและเล็งพื้น การทำตามลำดับขั้นตอนที่ถูกต้องช่วยให้งานสำเร็จ'),
  ('A',8,2,'AR ต้องใช้กล้อง แสงสว่างพอ และพื้นที่ให้วางโมเดล จึงควรตรวจสิ่งเหล่านี้ก่อน'),
  ('A',9,3,'หน้าเว็บที่เปิดให้หมุนได้ จะหมุนโมเดลตามการลากนิ้วบนหน้าจอ'),
  ('A',10,1,'การแบ่งปัญหาใหญ่เป็นส่วนย่อย ๆ ช่วยให้ทำงานง่ายขึ้น เป็นแนวคิดหนึ่งของการคิดเชิงคำนวณ'),
  ('B',1,2,'AR ผสมภาพเสมือนเข้ากับภาพของจริงที่กล้องมองเห็น'),
  ('B',2,0,'VR พาผู้ใช้เข้าไปในโลกเสมือน ส่วนการเห็นภาพเสมือนวางบนของจริงเป็นลักษณะของ AR'),
  ('B',3,3,'มือถือหรือแท็บเล็ตมีกล้องและหน้าจอสำหรับแสดงภาพเสมือนซ้อนกับของจริง'),
  ('B',4,1,'โมเดลเสมือนที่ปรากฏบนพื้นห้องจริงผ่านกล้องมือถือ คือการใช้ AR'),
  ('B',5,2,'หน้าเว็บ AR เปิดได้จากลิงก์หรือ QR code และมีปุ่มสำหรับเปิดโหมด AR'),
  ('B',6,0,'ควรใช้กล้องเพื่อการเรียนตามที่ครูอนุญาต และต้องขออนุญาตก่อนถ่ายภาพผู้อื่น'),
  ('B',7,3,'ต้องสแกนเพื่อเปิดหน้าเว็บก่อนจึงมีปุ่ม AR แล้วจึงอนุญาตกล้อง การเรียงขั้นตอนให้ถูกช่วยให้ทำงานสำเร็จ'),
  ('B',8,1,'AR ต้องใช้กล้องมองสิ่งรอบตัว จึงต้องมีแสงพอและอนุญาตให้ใช้กล้อง'),
  ('B',9,0,'การลากนิ้วบนโมเดลทำให้โมเดลหมุน จึงดูด้านหลังได้'),
  ('B',10,2,'การแบ่งงานใหญ่เป็นงานย่อยช่วยให้ทำทีละส่วนได้ง่ายขึ้น')
on conflict (form, q) do update set ans = excluded.ans, why = excluded.why;

-- เลือกชุดข้อสอบตามเลขท้ายเลขประจำตัว: คู่ = ก่อนเรียนชุด A / หลังเรียนชุด B, คี่ = ก่อนเรียนชุด B / หลังเรียนชุด A
create or replace function public.test_form(p_kind text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare d int;
begin
  if p_kind not in ('pre','post') then raise exception 'ชนิดแบบทดสอบไม่ถูกต้อง'; end if;
  select (right(id,1))::int into d from public.students where user_id = auth.uid();
  if d is null then raise exception 'เฉพาะผู้เรียนที่ลงทะเบียน'; end if;
  return case when (d % 2 = 0) = (p_kind = 'pre') then 'A' else 'B' end;
end $$;

-- ส่งแบบทดสอบ: ตรวจคะแนนในฐานข้อมูล ผู้เรียนส่งคะแนนเองไม่ได้
create or replace function public.submit_attempt(p_kind text, p_answers int[]) returns int
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_form text; v_score int;
begin
  if not public.is_student() then raise exception 'เฉพาะผู้เรียนที่ลงทะเบียน'; end if;
  if p_kind not in ('pre','post') then raise exception 'ชนิดแบบทดสอบไม่ถูกต้อง'; end if;
  if coalesce(array_length(p_answers,1),0) <> 10 then raise exception 'ต้องส่งคำตอบ 10 ข้อ'; end if;
  if p_kind = 'post' then
    if not exists (select 1 from public.attempts where user_id = v_uid and kind = 'pre') then
      raise exception 'ต้องทำแบบทดสอบก่อนเรียนก่อน';
    end if;
    if (select count(*) from public.progress where user_id = v_uid and done) < 5 then
      raise exception 'ต้องเรียนให้ครบ 5 หน่วยก่อนทำแบบทดสอบหลังเรียน';
    end if;
  end if;
  v_form := public.test_form(p_kind);
  select count(*) into v_score from public.test_keys k where k.form = v_form and k.ans = p_answers[k.q];
  insert into public.attempts(user_id, kind, score, answers, form)
    values (v_uid, p_kind, v_score, to_jsonb(p_answers), v_form);
  return v_score;
end $$;

-- เฉลยและคำอธิบายของแบบทดสอบหลังเรียน: ให้ได้เฉพาะเมื่อผู้เรียนส่งแบบทดสอบหลังเรียนแล้ว (ก่อนเรียนไม่เปิดเฉลย)
create or replace function public.post_review() returns table(q int, ans int, why text)
language plpgsql stable security definer set search_path = '' as $$
declare v_form text;
begin
  select a.form into v_form from public.attempts a where a.user_id = auth.uid() and a.kind = 'post';
  if v_form is null then raise exception 'ต้องทำแบบทดสอบหลังเรียนก่อน'; end if;
  return query select k.q, k.ans, k.why from public.test_keys k where k.form = v_form order by k.q;
end $$;

-- ผู้สอนดูเฉลยทั้งสองชุด
create or replace function public.teacher_keys() returns setof public.test_keys
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_teacher() then raise exception 'เฉพาะผู้สอน'; end if;
  return query select * from public.test_keys order by form, q;
end $$;

-- ---------- 5) มุมมองสรุปผล (security_invoker: ใช้สิทธิ์/RLS ของผู้เรียกจริง) ----------
-- คะแนนเต็มแบบทดสอบ = 10; normalized gain = (post-pre)/(10-pre) ; ถ้า pre = 10 จะเป็นค่าว่าง (คำนวณไม่ได้)
drop view if exists public.results;
create view public.results with (security_invoker = true) as
select t.*,
  case when pre_score is not null and post_score is not null and pre_score < 10
       then round((post_score - pre_score)::numeric / (10 - pre_score), 2) end as norm_gain
from (
  select s.id as student_id, s.title, s.first_name, s.last_name, s.section,
    (s.user_id is not null) as registered, s.photo_path,
    (select a.score from public.attempts a where a.user_id = s.user_id and a.kind = 'pre')  as pre_score,
    (select a.score from public.attempts a where a.user_id = s.user_id and a.kind = 'post') as post_score,
    (select count(*) from public.progress p where p.user_id = s.user_id and p.done)        as units_done,
    (select count(*) from public.submissions x where x.user_id = s.user_id)                as submissions,
    (select max(x.score) from public.submissions x where x.user_id = s.user_id)            as best_work_score
  from public.students s
) t;

-- ---------- 6) RLS ----------
alter table public.teachers    enable row level security;
alter table public.students    enable row level security;
alter table public.attempts    enable row level security;
alter table public.test_keys   enable row level security;
alter table public.progress    enable row level security;
alter table public.submissions enable row level security;
alter table public.materials   enable row level security;

do $$ declare p record; begin
  for p in select policyname, tablename from pg_policies where schemaname = 'public' loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

create policy teachers_sel on public.teachers for select to authenticated using (user_id = auth.uid());

create policy stu_sel on public.students for select to authenticated using (user_id = auth.uid() or public.is_teacher());
create policy stu_upd on public.students for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy att_sel on public.attempts for select to authenticated using (user_id = auth.uid() or public.is_teacher());
-- attempts: ไม่มีนโยบาย insert/update/delete ให้ผู้ใช้ เพิ่มได้ผ่านฟังก์ชัน submit_attempt เท่านั้น
-- test_keys: ไม่มีนโยบายใด ๆ = ผู้ใช้ทั่วไปอ่านและเขียนตรง ๆ ไม่ได้ เข้าถึงผ่าน post_review / teacher_keys เท่านั้น

create policy prg_sel on public.progress for select to authenticated using (user_id = auth.uid() or public.is_teacher());
create policy prg_ins on public.progress for insert to authenticated with check (user_id = auth.uid() and public.is_student());
create policy prg_upd on public.progress for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy sub_sel on public.submissions for select to authenticated using (user_id = auth.uid() or public.is_teacher());
create policy sub_ins on public.submissions for insert to authenticated with check (user_id = auth.uid() and public.is_student());
create policy sub_upd on public.submissions for update to authenticated using (public.is_teacher()) with check (public.is_teacher());

create policy mat_sel on public.materials for select to authenticated using (public.is_member());
create policy mat_wr  on public.materials for all    to authenticated using (public.is_teacher()) with check (public.is_teacher());

-- ---------- 7) สิทธิ์ระดับตาราง/คอลัมน์ ----------
-- วิธีกันผู้เรียนแก้ score / teacher_comment (2 ชั้น):
--  (ก) สิทธิ์ INSERT บน submissions ไม่รวมคอลัมน์ score/teacher_comment (จึงได้ค่า null เสมอ)
--  (ข) นโยบาย RLS sub_upd อนุญาต UPDATE เฉพาะ is_teacher() ผู้เรียนที่สั่งแก้จะไม่มีแถวใดถูกแก้
--      (สิทธิ์คอลัมน์ score,teacher_comment ให้ role authenticated เพื่อให้ผู้สอนแก้ได้ แต่ผ่านนโยบายได้เฉพาะผู้สอน)
-- ผู้เรียนลบ/แก้งานที่ส่งไม่ได้ และแก้/ลบสื่อของผู้สอนไม่ได้ (mat_wr เฉพาะผู้สอน)
-- ในตาราง students ผู้เรียนมีสิทธิ์ UPDATE เฉพาะคอลัมน์ photo_path
revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from anon;
revoke execute on all functions in schema public from public;

grant select on public.teachers, public.students, public.attempts, public.progress,
                public.submissions, public.materials, public.results to authenticated;
grant update (photo_path) on public.students to authenticated;
grant insert (user_id, unit, done) on public.progress to authenticated;
grant update (done) on public.progress to authenticated;
grant insert (user_id, unit, kind, url, storage_path, note) on public.submissions to authenticated;
grant update (score, teacher_comment) on public.submissions to authenticated;
grant insert, update, delete on public.materials to authenticated;
grant execute on function public.is_teacher(), public.is_student(), public.is_member(),
                          public.test_form(text), public.submit_attempt(text, int[]),
                          public.post_review(), public.teacher_keys() to authenticated;

-- ---------- 8) Storage (private ทั้งหมด จำกัดชนิดและขนาดไฟล์) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
 ('photos','photos', false, 2*1024*1024,  array['image/png','image/jpeg']),
 ('submissions','submissions', false, 20*1024*1024, array['image/png','image/jpeg','application/pdf','video/mp4']),
 ('materials','materials', false, 50*1024*1024, array[
   'application/vnd.openxmlformats-officedocument.presentationml.presentation',
   'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
   'application/pdf'])
on conflict (id) do update set public = false,
  file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'ar\_%' loop
    execute format('drop policy %I on storage.objects', p.policyname);
  end loop;
end $$;

-- ผู้เรียน: จัดการได้เฉพาะโฟลเดอร์ที่ชื่อ = uid ของตน (photos, submissions)
create policy ar_own on storage.objects for all to authenticated
  using      (bucket_id in ('photos','submissions') and public.is_student() and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id in ('photos','submissions') and public.is_student() and (storage.foldername(name))[1] = auth.uid()::text);
-- ผู้สอน: อ่านได้ทั้ง photos และ submissions
create policy ar_teacher_read on storage.objects for select to authenticated
  using (bucket_id in ('photos','submissions') and public.is_teacher());
-- materials: สมาชิกอ่านได้ ผู้สอนเขียนได้
create policy ar_mat_read  on storage.objects for select to authenticated
  using (bucket_id = 'materials' and public.is_member());
create policy ar_mat_write on storage.objects for all to authenticated
  using (bucket_id = 'materials' and public.is_teacher())
  with check (bucket_id = 'materials' and public.is_teacher());

-- ---------- 9) รายชื่อผู้เรียน: ข้อมูลจำลอง 6 แถวเท่านั้น (ไม่ใช่บุคคลจริง) ----------
-- นำเข้ารายชื่อจริง 40 คน: Table Editor > students > Insert > Import data from CSV (ใช้ students_template.csv เป็นแบบ)
-- คอลัมน์ในไฟล์ CSV: id,title,first_name,last_name,section  (ไม่ต้องใส่ user_id, photo_path)
-- ลบ 6 แถวจำลองนี้ก่อนใช้งานจริง
insert into public.students (id, title, first_name, last_name, section) values
 ('00001','ด.ช.','ตัวอย่างหนึ่ง','ทดสอบ','1'),
 ('00002','ด.ญ.','ตัวอย่างสอง','ทดสอบ','1'),
 ('00003','ด.ช.','ตัวอย่างสาม','ทดสอบ','1'),
 ('00004','ด.ญ.','ตัวอย่างสี่','ทดสอบ','1'),
 ('00005','ด.ช.','ตัวอย่างห้า','ทดสอบ','1'),
 ('00006','ด.ญ.','ตัวอย่างหก','ทดสอบ','1')
on conflict (id) do nothing;

-- ---------- 10) ตั้งผู้สอน (ผู้สอนสมัครบัญชีในหน้าเว็บด้วยอีเมลจริงก่อน แล้วเปิดคอมเมนต์นี้ แก้อีเมล และรัน) ----------
/*
insert into public.teachers (user_id)
select id from auth.users where email = 'teacher@example.com'   -- <- แก้เป็นอีเมลผู้สอน
on conflict do nothing;
*/
