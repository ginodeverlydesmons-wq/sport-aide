-- =====================================================================
-- Appli de musculation communautaire : schéma Supabase (PostgreSQL)
-- À coller dans Supabase > SQL Editor, puis exécuter en une fois.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TYPES
-- ---------------------------------------------------------------------
create type user_role     as enum ('user', 'coach', 'moderator', 'admin');
create type skill_level   as enum ('beginner', 'intermediate', 'advanced');
create type body_side     as enum ('front', 'back');
create type muscle_role   as enum ('primary', 'secondary');
create type video_source  as enum ('youtube', 'upload');
create type video_status  as enum ('pending', 'published', 'under_review', 'hidden', 'removed');
create type report_reason as enum ('dangerous', 'wrong_exercise', 'spam', 'inappropriate', 'copyright', 'broken_link', 'other');
create type report_status as enum ('open', 'reviewed', 'dismissed');
create type coach_verdict as enum ('validated', 'needs_correction');

-- ---------------------------------------------------------------------
-- 2. LANGUES ET PROFILS
-- ---------------------------------------------------------------------
create table languages (
  code text primary key,           -- 'fr', 'en', ...
  name text not null               -- nom affiché dans le sélecteur de langue
);

create table profiles (
  id             uuid primary key references auth.users (id) on delete cascade,
  username       text not null unique check (char_length(username) between 3 and 40),
  avatar_url     text,
  role           user_role not null default 'user',
  reputation     integer   not null default 0,
  interface_lang text references languages (code) default 'fr',
  level          skill_level not null default 'beginner',
  created_at     timestamptz not null default now()
);

-- Fonctions utilitaires de rôle (security definer pour éviter la récursion RLS)
create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role in ('moderator', 'admin')
  );
$$;

create or replace function is_coach() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role in ('coach', 'moderator', 'admin')
  );
$$;

-- Création automatique du profil à l'inscription
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, username)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1))
      || '_' || substr(md5(random()::text), 1, 4)
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ---------------------------------------------------------------------
-- 3. MUSCLES (avec traductions)
-- ---------------------------------------------------------------------
create table muscle_groups (
  id         bigint generated always as identity primary key,
  slug       text not null unique,
  sort_order integer not null default 0
);

create table muscle_group_translations (
  group_id bigint not null references muscle_groups (id) on delete cascade,
  lang     text   not null references languages (code),
  name     text   not null,
  primary key (group_id, lang)
);

create table muscles (
  id          bigint generated always as identity primary key,
  slug        text not null unique,
  group_id    bigint not null references muscle_groups (id),
  latin_name  text,
  side        body_side not null,          -- face ou dos sur la carte
  svg_zone_id text not null unique         -- id de la zone cliquable dans le SVG
);

create table muscle_translations (
  muscle_id bigint not null references muscles (id) on delete cascade,
  lang      text   not null references languages (code),
  name      text   not null,
  primary key (muscle_id, lang)
);

create index on muscles (group_id);

-- ---------------------------------------------------------------------
-- 4. EXERCICES (catalogue géré par l'équipe, avec traductions)
-- ---------------------------------------------------------------------
create table exercises (
  id         bigint generated always as identity primary key,
  slug       text not null unique,
  level      skill_level not null default 'beginner',
  equipment  text[] not null default '{}',   -- ex : {'bodyweight'}, {'dumbbell','bench'}
  status     text not null default 'published' check (status in ('draft', 'published')),
  created_at timestamptz not null default now()
);

create table exercise_translations (
  exercise_id bigint not null references exercises (id) on delete cascade,
  lang        text   not null references languages (code),
  name        text   not null,
  description text,
  primary key (exercise_id, lang)
);

-- Liaison N-N : un exercice sollicite plusieurs muscles
create table exercise_muscles (
  exercise_id bigint not null references exercises (id) on delete cascade,
  muscle_id   bigint not null references muscles (id) on delete cascade,
  role        muscle_role not null default 'primary',
  primary key (exercise_id, muscle_id)
);

create index on exercise_muscles (muscle_id);

-- ---------------------------------------------------------------------
-- 5. VIDÉOS (liens YouTube au départ, upload natif plus tard)
-- ---------------------------------------------------------------------
create table videos (
  id               bigint generated always as identity primary key,
  exercise_id      bigint not null references exercises (id) on delete cascade,
  user_id          uuid   not null references profiles (id) on delete cascade,
  source           video_source not null default 'youtube',
  external_id      text,                      -- identifiant YouTube (11 caractères)
  storage_path     text,                      -- pour les uploads natifs (évolution)
  title            text,
  thumbnail_url    text,
  duration_seconds integer,
  language         text references languages (code),
  level            skill_level not null default 'beginner',
  status           video_status not null default 'pending',
  is_reference     boolean not null default false,   -- vidéo épinglée par les modos
  coach_validated  boolean not null default false,
  score            integer not null default 0,
  vote_count       integer not null default 0,
  report_count     integer not null default 0,
  created_at       timestamptz not null default now(),
  constraint source_has_id check (
    (source = 'youtube' and external_id is not null) or
    (source = 'upload'  and storage_path is not null)
  ),
  unique (exercise_id, source, external_id)
);

create index on videos (exercise_id, status, score desc);
create index on videos (user_id);

-- Les champs sensibles sont imposés côté serveur à la création
create or replace function videos_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  p profiles%rowtype;
begin
  select * into p from profiles where id = new.user_id;

  new.score := 0;
  new.vote_count := 0;
  new.report_count := 0;
  new.coach_validated := false;
  new.is_reference := false;

  -- Période probatoire : publication directe uniquement pour les comptes de confiance
  if p.role in ('coach', 'moderator', 'admin') or p.reputation >= 20 then
    new.status := 'published';
  else
    new.status := 'pending';
  end if;

  return new;
end;
$$;

create trigger videos_before_insert
  before insert on videos
  for each row execute function videos_before_insert();

-- ---------------------------------------------------------------------
-- 6. VOTES
-- ---------------------------------------------------------------------
create table votes (
  user_id    uuid   not null references profiles (id) on delete cascade,
  video_id   bigint not null references videos (id) on delete cascade,
  value      smallint not null check (value in (-1, 1)),
  created_at timestamptz not null default now(),
  primary key (user_id, video_id)
);

create index on votes (video_id);

-- Recalcule score, réputation de l'auteur et masque automatiquement
-- une vidéo très mal notée (au moins 5 votes et score <= -5)
create or replace function apply_vote() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_id   bigint;
  author uuid;
  delta  integer;
begin
  if tg_op = 'INSERT' then
    v_id := new.video_id;  delta := new.value;
  elsif tg_op = 'UPDATE' then
    v_id := new.video_id;  delta := new.value - old.value;
  else
    v_id := old.video_id;  delta := -old.value;
  end if;

  update videos
     set score      = (select coalesce(sum(value), 0) from votes where video_id = v_id),
         vote_count = (select count(*) from votes where video_id = v_id)
   where id = v_id
   returning user_id into author;

  if author is not null then
    update profiles set reputation = reputation + delta where id = author;
  end if;

  update videos
     set status = 'under_review'
   where id = v_id and status = 'published' and vote_count >= 5 and score <= -5;

  return null;
end;
$$;

create trigger votes_apply
  after insert or update or delete on votes
  for each row execute function apply_vote();

-- ---------------------------------------------------------------------
-- 7. SIGNALEMENTS
-- ---------------------------------------------------------------------
create table reports (
  id         bigint generated always as identity primary key,
  video_id   bigint not null references videos (id) on delete cascade,
  user_id    uuid   not null references profiles (id) on delete cascade,
  reason     report_reason not null,
  details    text,
  status     report_status not null default 'open',
  handled_by uuid references profiles (id),
  created_at timestamptz not null default now(),
  unique (video_id, user_id)               -- un seul signalement par personne et par vidéo
);

create index on reports (video_id);
create index on reports (status);

-- À partir de 3 signalements, la vidéo passe en revue
create or replace function apply_report() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update videos set report_count = report_count + 1 where id = new.video_id;

  update videos
     set status = 'under_review'
   where id = new.video_id and status = 'published' and report_count >= 3;

  return null;
end;
$$;

create trigger reports_apply
  after insert on reports
  for each row execute function apply_report();

-- ---------------------------------------------------------------------
-- 8. VALIDATIONS PAR LES COACHS
-- ---------------------------------------------------------------------
create table coach_validations (
  video_id   bigint not null references videos (id) on delete cascade,
  coach_id   uuid   not null references profiles (id) on delete cascade,
  verdict    coach_verdict not null,
  comment    text,
  created_at timestamptz not null default now(),
  primary key (video_id, coach_id)
);

create or replace function apply_coach_validation() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_id bigint;
begin
  v_id := coalesce(new.video_id, old.video_id);

  update videos
     set coach_validated = exists (
       select 1 from coach_validations
       where video_id = v_id and verdict = 'validated'
     )
   where id = v_id;

  return null;
end;
$$;

create trigger coach_validations_apply
  after insert or update or delete on coach_validations
  for each row execute function apply_coach_validation();

-- ---------------------------------------------------------------------
-- 9. FAVORIS
-- ---------------------------------------------------------------------
create table favorites (
  user_id    uuid   not null references profiles (id) on delete cascade,
  video_id   bigint not null references videos (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, video_id)
);

-- ---------------------------------------------------------------------
-- 10. FONCTIONS MÉTIER (appelées depuis l'appli)
-- ---------------------------------------------------------------------

-- Cœur de l'appli : les exercices d'un muscle, dans la langue choisie,
-- avec repli sur l'anglais si la traduction manque.
create or replace function exercises_by_muscle(
  p_muscle_slug text,
  p_lang        text default 'fr',
  p_level       skill_level default null
)
returns table (
  exercise_id      bigint,
  exercise_slug    text,
  exercise_name    text,
  exercise_level   skill_level,
  equipment        text[],
  role_in_exercise muscle_role,
  video_count      bigint,
  top_video_id     bigint
)
language sql stable as $$
  select
    e.id,
    e.slug,
    coalesce(t.name, te.name),
    e.level,
    e.equipment,
    em.role,
    (select count(*) from videos v
      where v.exercise_id = e.id and v.status = 'published'),
    (select v.id from videos v
      where v.exercise_id = e.id and v.status = 'published'
      order by v.is_reference desc, v.coach_validated desc, v.score desc
      limit 1)
  from muscles m
  join exercise_muscles em on em.muscle_id = m.id
  join exercises e on e.id = em.exercise_id and e.status = 'published'
  left join exercise_translations t  on t.exercise_id  = e.id and t.lang  = p_lang
  left join exercise_translations te on te.exercise_id = e.id and te.lang = 'en'
  where m.slug = p_muscle_slug
    and (p_level is null or e.level = p_level)
  order by em.role, e.slug;
$$;

-- Modération : réservée aux modérateurs et admins
create or replace function moderate_video(
  p_video_id     bigint,
  p_status       video_status,
  p_is_reference boolean default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then
    raise exception 'forbidden';
  end if;

  update videos
     set status       = p_status,
         is_reference = coalesce(p_is_reference, is_reference)
   where id = p_video_id;
end;
$$;

revoke all on function moderate_video(bigint, video_status, boolean) from public, anon;
grant execute on function moderate_video(bigint, video_status, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 11. SÉCURITÉ : ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
alter table languages                 enable row level security;
alter table profiles                  enable row level security;
alter table muscle_groups             enable row level security;
alter table muscle_group_translations enable row level security;
alter table muscles                   enable row level security;
alter table muscle_translations       enable row level security;
alter table exercises                 enable row level security;
alter table exercise_translations     enable row level security;
alter table exercise_muscles          enable row level security;
alter table videos                    enable row level security;
alter table votes                     enable row level security;
alter table reports                   enable row level security;
alter table coach_validations         enable row level security;
alter table favorites                 enable row level security;

-- Catalogue : lecture publique, écriture réservée au staff
do $$
declare t text;
begin
  foreach t in array array[
    'languages', 'muscle_groups', 'muscle_group_translations',
    'muscles', 'muscle_translations', 'exercise_translations', 'exercise_muscles'
  ] loop
    execute format('create policy "lecture publique" on public.%I for select using (true)', t);
    execute format('create policy "ecriture staff" on public.%I for all using (is_staff()) with check (is_staff())', t);
  end loop;
end $$;

create policy "exercices publies visibles" on exercises
  for select using (status = 'published');
create policy "exercices staff" on exercises
  for all using (is_staff()) with check (is_staff());

-- Profils : lisibles par tous, modifiables par leur propriétaire (colonnes limitées)
create policy "profils lisibles" on profiles for select using (true);
create policy "profil modifiable par soi" on profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

revoke update on profiles from authenticated, anon;
grant update (username, avatar_url, interface_lang, level) on profiles to authenticated;

-- Vidéos
create policy "videos visibles" on videos
  for select using (status = 'published' or user_id = auth.uid() or is_staff());
create policy "ajout de video" on videos
  for insert to authenticated with check (user_id = auth.uid());
create policy "modifier sa video" on videos
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "supprimer sa video ou staff" on videos
  for delete to authenticated using (user_id = auth.uid() or is_staff());

revoke update on videos from authenticated, anon;
grant update (title, language, level) on videos to authenticated;

-- Votes : on ne vote que sur une vidéo publiée qui n'est pas la sienne
create policy "voir son vote" on votes
  for select to authenticated using (user_id = auth.uid());
create policy "voter" on votes
  for insert to authenticated with check (
    user_id = auth.uid()
    and exists (
      select 1 from videos v
      where v.id = video_id and v.status = 'published' and v.user_id <> auth.uid()
    )
  );
create policy "changer son vote" on votes
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "retirer son vote" on votes
  for delete to authenticated using (user_id = auth.uid());

-- Signalements
create policy "signaler" on reports
  for insert to authenticated with check (user_id = auth.uid());
create policy "voir ses signalements ou staff" on reports
  for select to authenticated using (user_id = auth.uid() or is_staff());
create policy "traiter les signalements" on reports
  for update to authenticated using (is_staff()) with check (is_staff());

-- Validations coach
create policy "validations visibles" on coach_validations for select using (true);
create policy "coach valide" on coach_validations
  for insert to authenticated with check (coach_id = auth.uid() and is_coach());
create policy "coach modifie sa validation" on coach_validations
  for update to authenticated using (coach_id = auth.uid() and is_coach())
  with check (coach_id = auth.uid() and is_coach());
create policy "coach retire sa validation" on coach_validations
  for delete to authenticated using (coach_id = auth.uid());

-- Favoris
create policy "favoris perso" on favorites
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- 12. DONNÉES DE DÉPART (exemple, à étendre à ~40 muscles / ~150 exercices)
-- ---------------------------------------------------------------------
insert into languages (code, name) values
  ('fr', 'Français'),
  ('en', 'English')
on conflict do nothing;

insert into muscle_groups (slug, sort_order) values
  ('chest', 1), ('back', 2), ('shoulders', 3), ('arms', 4), ('legs', 5), ('core', 6)
on conflict do nothing;

insert into muscle_group_translations (group_id, lang, name)
select g.id, v.lang, v.name
from (values
  ('chest', 'fr', 'Poitrine'),   ('chest', 'en', 'Chest'),
  ('back', 'fr', 'Dos'),         ('back', 'en', 'Back'),
  ('shoulders', 'fr', 'Épaules'),('shoulders', 'en', 'Shoulders'),
  ('arms', 'fr', 'Bras'),        ('arms', 'en', 'Arms'),
  ('legs', 'fr', 'Jambes'),      ('legs', 'en', 'Legs'),
  ('core', 'fr', 'Abdominaux'),  ('core', 'en', 'Core')
) as v(slug, lang, name)
join muscle_groups g on g.slug = v.slug
on conflict do nothing;

insert into muscles (slug, group_id, latin_name, side, svg_zone_id)
select v.slug, g.id, v.latin_name, v.side::body_side, 'zone-' || v.slug
from (values
  ('pectoralis-major', 'chest',     'Pectoralis major',  'front'),
  ('latissimus-dorsi', 'back',      'Latissimus dorsi',  'back'),
  ('trapezius',        'back',      'Trapezius',         'back'),
  ('deltoids',         'shoulders', 'Deltoideus',        'front'),
  ('biceps-brachii',   'arms',      'Biceps brachii',    'front'),
  ('triceps-brachii',  'arms',      'Triceps brachii',   'back'),
  ('forearms',         'arms',      'Antebrachium',      'front'),
  ('abdominals',       'core',      'Rectus abdominis',  'front'),
  ('quadriceps',       'legs',      'Quadriceps femoris','front'),
  ('hamstrings',       'legs',      'Ischiocrurals',     'back'),
  ('glutes',           'legs',      'Gluteus maximus',   'back'),
  ('calves',           'legs',      'Triceps surae',     'back')
) as v(slug, group_slug, latin_name, side)
join muscle_groups g on g.slug = v.group_slug
on conflict do nothing;

insert into muscle_translations (muscle_id, lang, name)
select m.id, v.lang, v.name
from (values
  ('pectoralis-major', 'fr', 'Pectoraux'),        ('pectoralis-major', 'en', 'Pectorals'),
  ('latissimus-dorsi', 'fr', 'Grand dorsal'),     ('latissimus-dorsi', 'en', 'Lats'),
  ('trapezius',        'fr', 'Trapèzes'),         ('trapezius',        'en', 'Trapezius'),
  ('deltoids',         'fr', 'Deltoïdes'),        ('deltoids',         'en', 'Deltoids'),
  ('biceps-brachii',   'fr', 'Biceps'),           ('biceps-brachii',   'en', 'Biceps'),
  ('triceps-brachii',  'fr', 'Triceps'),          ('triceps-brachii',  'en', 'Triceps'),
  ('forearms',         'fr', 'Avant-bras'),       ('forearms',         'en', 'Forearms'),
  ('abdominals',       'fr', 'Abdominaux'),       ('abdominals',       'en', 'Abs'),
  ('quadriceps',       'fr', 'Quadriceps'),       ('quadriceps',       'en', 'Quadriceps'),
  ('hamstrings',       'fr', 'Ischio-jambiers'),  ('hamstrings',       'en', 'Hamstrings'),
  ('glutes',           'fr', 'Fessiers'),         ('glutes',           'en', 'Glutes'),
  ('calves',           'fr', 'Mollets'),          ('calves',           'en', 'Calves')
) as v(slug, lang, name)
join muscles m on m.slug = v.slug
on conflict do nothing;

insert into exercises (slug, level, equipment) values
  ('push-up',     'beginner', '{bodyweight}'),
  ('biceps-curl', 'beginner', '{dumbbell}'),
  ('calf-raise',  'beginner', '{bodyweight}')
on conflict do nothing;

insert into exercise_translations (exercise_id, lang, name, description)
select e.id, v.lang, v.name, v.description
from (values
  ('push-up',     'fr', 'Pompes',               'Mains à largeur d''épaules, corps gainé, descendre la poitrine vers le sol puis pousser.'),
  ('push-up',     'en', 'Push-ups',             'Hands shoulder-width apart, body straight, lower your chest to the floor then push back up.'),
  ('biceps-curl', 'fr', 'Curl biceps haltères', 'Coudes près du corps, fléchir l''avant-bras sans balancer le buste.'),
  ('biceps-curl', 'en', 'Dumbbell biceps curl', 'Keep elbows close to your body and curl without swinging your torso.'),
  ('calf-raise',  'fr', 'Extensions mollets',   'Debout, monter sur la pointe des pieds puis redescendre lentement.'),
  ('calf-raise',  'en', 'Calf raises',          'Stand tall, rise onto your toes then lower slowly.')
) as v(slug, lang, name, description)
join exercises e on e.slug = v.slug
on conflict do nothing;

insert into exercise_muscles (exercise_id, muscle_id, role)
select e.id, m.id, v.role::muscle_role
from (values
  ('push-up',     'pectoralis-major', 'primary'),
  ('push-up',     'triceps-brachii',  'secondary'),
  ('push-up',     'deltoids',         'secondary'),
  ('biceps-curl', 'biceps-brachii',   'primary'),
  ('biceps-curl', 'forearms',         'secondary'),
  ('calf-raise',  'calves',           'primary')
) as v(exercise_slug, muscle_slug, role)
join exercises e on e.slug = v.exercise_slug
join muscles   m on m.slug = v.muscle_slug
on conflict do nothing;

-- Test rapide une fois exécuté :
--   select * from exercises_by_muscle('biceps-brachii', 'fr');
