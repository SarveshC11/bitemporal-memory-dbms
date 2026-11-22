-- =====================================================================
-- 007_demo_data.sql  --  demo dataset (fully fictional people and organisations)
-- Four made-up people: Ilina (main story), Rehaan, Mahika and Darsh.
-- Every write goes through log_source()/remember() and the correction
-- functions, with memory.txn_time replayed, so both timelines and the
-- correction audit look realistic. Runs after 004_seed.sql; the Priya/Rohan
-- seed data is left untouched.
-- =====================================================================
DO $$
DECLARE s bigint; f bigint;
BEGIN
  -- ===== Ilina: profile chat =====
  PERFORM set_config('memory.txn_time', '2026-01-14 19:10:00+05:30', false);
  s := log_source('ilina-profile', 1, 'user', 'Hi, I''m Ilina. I''m a research assistant in marine biology and I''ve lived in Kochi since June 2022. I speak Malayalam, English and French.', '2026-01-14 19:10:00+05:30');
  PERFORM remember('Ilina', 'lives_in', 'Kochi', s, '2022-06-01 00:00:00+05:30', 0.95, p_object_type => 'place');
  PERFORM remember('Ilina', 'has_role', 'Research Assistant', s, '2023-09-01 00:00:00+05:30', 0.95);
  PERFORM remember('Ilina', 'speaks', 'Malayalam', s, '2026-01-14 19:10:00+05:30', 0.95);
  PERFORM remember('Ilina', 'speaks', 'English',   s, '2026-01-14 19:10:00+05:30', 0.95);
  PERFORM remember('Ilina', 'speaks', 'French',    s, '2026-01-14 19:10:00+05:30', 0.80);

  PERFORM set_config('memory.txn_time', '2026-02-05 21:30:00+05:30', false);
  s := log_source('ilina-profile', 2, 'user', 'I love scuba diving, birdwatching and sci-fi novels. My favourite food is appam with stew.', '2026-02-05 21:30:00+05:30');
  PERFORM remember('Ilina', 'likes', 'scuba diving',  s, '2026-02-05 21:30:00+05:30');
  PERFORM remember('Ilina', 'likes', 'birdwatching',  s, '2026-02-05 21:30:00+05:30');
  PERFORM remember('Ilina', 'likes', 'sci-fi',        s, '2026-02-05 21:30:00+05:30', 0.85);
  PERFORM remember('Ilina', 'favourite_food', 'Appam with Stew', s, '2026-02-05 21:30:00+05:30', 0.90);

  PERFORM set_config('memory.txn_time', '2026-02-22 18:05:00+05:30', false);
  s := log_source('ilina-profile', 3, 'user', 'At work I mostly do coral taxonomy and GIS mapping, and I analyse survey data in R.', '2026-02-22 18:05:00+05:30');
  PERFORM remember('Ilina', 'skilled_in', 'Coral taxonomy', s, '2026-02-22 18:05:00+05:30');
  PERFORM remember('Ilina', 'skilled_in', 'GIS mapping',    s, '2026-02-22 18:05:00+05:30');
  PERFORM remember('Ilina', 'skilled_in', 'R',              s, '2026-02-22 18:05:00+05:30', 0.80);

  -- ===== Ilina: field fellowship chat =====
  PERFORM set_config('memory.txn_time', '2026-04-16 18:45:00+05:30', false);
  s := log_source('ilina-fieldwork', 1, 'user', 'Great news: I accepted a field fellowship at the Coral Reef Institute as a Field Fellow, starting 1 June.', '2026-04-16 18:45:00+05:30');
  PERFORM remember('Ilina', 'works_at', 'Coral Reef Institute', s, '2026-06-01 00:00:00+05:30', 0.90, p_object_type => 'org');
  PERFORM remember('Ilina', 'has_role', 'Field Fellow', s, '2026-06-01 00:00:00+05:30', 0.90);

  PERFORM set_config('memory.txn_time', '2026-06-04 09:20:00+05:30', false);
  s := log_source('ilina-fieldwork', 2, 'user', 'Moved to Port Blair on 30 May for the fellowship. The station is right by the jetty.', '2026-06-04 09:20:00+05:30');
  PERFORM remember('Ilina', 'lives_in', 'Port Blair', s, '2026-05-30 00:00:00+05:30', 0.90, p_object_type => 'place');

  -- A CORRECTION: same employer, earlier valid start. The old belief stays on record.
  PERFORM set_config('memory.txn_time', '2026-06-21 20:00:00+05:30', false);
  s := log_source('ilina-fieldwork', 3, 'user', 'Small correction: the fellowship actually started on 25 May, not 1 June. The dive season opened early.', '2026-06-21 20:00:00+05:30');
  PERFORM remember('Ilina', 'works_at', 'Coral Reef Institute', s, '2026-05-25 00:00:00+05:30', 0.95, p_object_type => 'org');
  PERFORM remember('Ilina', 'has_role', 'Field Fellow', s, '2026-05-25 00:00:00+05:30', 0.95);

  PERFORM set_config('memory.txn_time', '2026-07-29 22:10:00+05:30', false);
  s := log_source('ilina-fieldwork', 4, 'user', 'Two months in, I''m now certified in scientific diving and drone surveying. Also got hooked on kayaking.', '2026-07-29 22:10:00+05:30');
  PERFORM remember('Ilina', 'skilled_in', 'Scientific diving', s, '2026-07-29 22:10:00+05:30');
  PERFORM remember('Ilina', 'skilled_in', 'Drone surveying',   s, '2026-07-29 22:10:00+05:30', 0.85);
  PERFORM remember('Ilina', 'likes', 'kayaking',               s, '2026-07-29 22:10:00+05:30');

  PERFORM set_config('memory.txn_time', '2026-08-04 11:00:00+05:30', false);
  s := log_source('ilina-fieldwork', 5, 'user', 'The field season ended on 31 July and the institute kept me on as a remote data curator. Back in Kochi since 1 August.', '2026-08-04 11:00:00+05:30');
  PERFORM remember('Ilina', 'has_role', 'Remote Data Curator', s, '2026-08-01 00:00:00+05:30', 0.90);
  PERFORM remember('Ilina', 'lives_in', 'Kochi', s, '2026-08-01 00:00:00+05:30', 0.95, p_object_type => 'place');

  -- ===== Ilina: back home =====
  PERFORM set_config('memory.txn_time', '2026-09-11 13:30:00+05:30', false);
  s := log_source('ilina-home', 1, 'user', 'Honestly my favourite food these days is fish moilee. The island canteen made it every Friday.', '2026-09-11 13:30:00+05:30');
  PERFORM remember('Ilina', 'favourite_food', 'Fish Moilee', s, '2026-09-11 13:30:00+05:30', 0.90);

  PERFORM set_config('memory.txn_time', '2026-10-06 17:15:00+05:30', false);
  s := log_source('ilina-home', 2, 'user', 'I''ve started recording reef sounds for a new project, so add bioacoustics to my skills.', '2026-10-06 17:15:00+05:30');
  PERFORM remember('Ilina', 'skilled_in', 'Bioacoustics', s, '2026-10-06 17:15:00+05:30');

  -- Dashboard corrections (fill the fact_corrections audit with all three actions)
  PERFORM set_config('memory.txn_time', '2026-10-09 10:00:00+05:30', false);
  SELECT fact_id INTO f FROM facts
   WHERE subject_id = ensure_entity('Ilina') AND object_text = 'sci-fi' AND upper_inf(sys_period);
  PERFORM replace_fact(f, 'science fiction', 'curator-01', 'Spell out the abbreviation extracted from turn 2');

  PERFORM set_config('memory.txn_time', '2026-10-13 16:40:00+05:30', false);
  SELECT f2.fact_id INTO f FROM facts f2
   WHERE f2.subject_id = ensure_entity('Ilina') AND f2.object_entity_id = ensure_entity('French')
     AND upper_inf(f2.sys_period);
  PERFORM reject_fact(f, 'curator-01', 'User said their French is only basic, asked to remove it');

  PERFORM set_config('memory.txn_time', '2026-10-21 09:05:00+05:30', false);
  PERFORM restore_fact(f, 'curator-02', 'User confirmed conversational French still counts');

  -- ===== Rehaan =====
  PERFORM set_config('memory.txn_time', '2026-01-27 18:00:00+05:30', false);
  s := log_source('rehaan', 1, 'user', 'I''m from Jaipur, lived here all my life. I speak Hindi and Marwari, and dal baati is my favourite food.', '2026-01-27 18:00:00+05:30');
  PERFORM remember('Rehaan', 'lives_in', 'Jaipur', s, '1998-03-14 00:00:00+05:30', 0.90, p_object_type => 'place');
  PERFORM remember('Rehaan', 'speaks', 'Hindi',   s, '2026-01-27 18:00:00+05:30');
  PERFORM remember('Rehaan', 'speaks', 'Marwari', s, '2026-01-27 18:00:00+05:30');
  PERFORM remember('Rehaan', 'favourite_food', 'Dal Baati', s, '2026-01-27 18:00:00+05:30');

  PERFORM set_config('memory.txn_time', '2026-03-03 20:30:00+05:30', false);
  s := log_source('rehaan', 2, 'user', 'I''ve been a sous chef at Marigold Kitchen since March 2024. Pastry and fermentation are my thing, and I restore vintage motorcycles on Sundays.', '2026-03-03 20:30:00+05:30');
  PERFORM remember('Rehaan', 'works_at', 'Marigold Kitchen', s, '2024-03-01 00:00:00+05:30', 0.95, p_object_type => 'org');
  PERFORM remember('Rehaan', 'has_role', 'Sous Chef', s, '2024-03-01 00:00:00+05:30', 0.95);
  PERFORM remember('Rehaan', 'skilled_in', 'Pastry',       s, '2026-03-03 20:30:00+05:30');
  PERFORM remember('Rehaan', 'skilled_in', 'Fermentation', s, '2026-03-03 20:30:00+05:30');
  PERFORM remember('Rehaan', 'likes', 'vintage motorcycles', s, '2026-03-03 20:30:00+05:30');

  PERFORM set_config('memory.txn_time', '2026-07-15 09:00:00+05:30', false);
  s := log_source('rehaan', 3, 'user', 'Promoted to Head Chef on 1 July!', '2026-07-15 09:00:00+05:30');
  PERFORM remember('Rehaan', 'has_role', 'Head Chef', s, '2026-07-01 00:00:00+05:30', 0.95);

  -- ===== Mahika =====
  PERFORM set_config('memory.txn_time', '2026-02-11 21:00:00+05:30', false);
  s := log_source('mahika', 1, 'user', 'I live in Lucknow and I''ve been a staff nurse at Lakeview Hospital since August 2023. Poha is my comfort food.', '2026-02-11 21:00:00+05:30');
  PERFORM remember('Mahika', 'lives_in', 'Lucknow', s, '2000-01-01 00:00:00+05:30', 0.90, p_object_type => 'place');
  PERFORM remember('Mahika', 'works_at', 'Lakeview Hospital', s, '2023-08-01 00:00:00+05:30', 0.95, p_object_type => 'org');
  PERFORM remember('Mahika', 'has_role', 'Staff Nurse', s, '2023-08-01 00:00:00+05:30', 0.95);
  PERFORM remember('Mahika', 'favourite_food', 'Poha', s, '2026-02-11 21:00:00+05:30');

  PERFORM set_config('memory.txn_time', '2026-04-05 19:45:00+05:30', false);
  s := log_source('mahika', 2, 'user', 'I''m trained in critical care and I unwind with pottery classes.', '2026-04-05 19:45:00+05:30');
  PERFORM remember('Mahika', 'skilled_in', 'Critical care', s, '2026-04-05 19:45:00+05:30');
  PERFORM remember('Mahika', 'likes', 'pottery',            s, '2026-04-05 19:45:00+05:30');

  PERFORM set_config('memory.txn_time', '2026-08-26 14:00:00+05:30', false);
  s := log_source('mahika', 3, 'user', 'New job: I joined Riverside Clinic as an ICU Nurse on 18 August and moved to Bhopal.', '2026-08-26 14:00:00+05:30');
  PERFORM remember('Mahika', 'works_at', 'Riverside Clinic', s, '2026-08-18 00:00:00+05:30', 0.90, p_object_type => 'org');
  PERFORM remember('Mahika', 'has_role', 'ICU Nurse', s, '2026-08-18 00:00:00+05:30', 0.90);
  PERFORM remember('Mahika', 'lives_in', 'Bhopal', s, '2026-08-16 00:00:00+05:30', 0.85, p_object_type => 'place');

  -- ===== Darsh =====
  PERFORM set_config('memory.txn_time', '2026-03-19 16:20:00+05:30', false);
  s := log_source('darsh', 1, 'user', 'I live in Shillong and teach violin at Hillside Conservatory since January 2025. Momos forever.', '2026-03-19 16:20:00+05:30');
  PERFORM remember('Darsh', 'lives_in', 'Shillong', s, '2019-06-01 00:00:00+05:30', 0.90, p_object_type => 'place');
  PERFORM remember('Darsh', 'works_at', 'Hillside Conservatory', s, '2025-01-06 00:00:00+05:30', 0.95, p_object_type => 'org');
  PERFORM remember('Darsh', 'has_role', 'Violin Teacher', s, '2025-01-06 00:00:00+05:30', 0.95);
  PERFORM remember('Darsh', 'favourite_food', 'Momos', s, '2026-03-19 16:20:00+05:30');
  PERFORM remember('Darsh', 'likes', 'trekking',     s, '2026-03-19 16:20:00+05:30');
  PERFORM remember('Darsh', 'skilled_in', 'Violin',  s, '2026-03-19 16:20:00+05:30');

  PERFORM set_config('memory.txn_time', '2026-09-02 10:15:00+05:30', false);
  s := log_source('darsh', 2, 'user', 'I became Head of Strings at the conservatory from today, and I''m also teaching music theory now.', '2026-09-02 10:15:00+05:30');
  PERFORM remember('Darsh', 'has_role', 'Head of Strings', s, '2026-09-02 00:00:00+05:30', 0.95);
  PERFORM remember('Darsh', 'skilled_in', 'Music theory', s, '2026-09-02 10:15:00+05:30');
END $$;

RESET memory.txn_time;

-- Extra spellings resolved by the alias table
INSERT INTO entity_aliases (alias, entity_id) VALUES
  ('cochin', ensure_entity('Kochi')),
  ('cri',    ensure_entity('Coral Reef Institute')),
  ('marigold', ensure_entity('Marigold Kitchen'))
ON CONFLICT (alias) DO NOTHING;
