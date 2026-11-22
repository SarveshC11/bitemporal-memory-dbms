-- =====================================================================
-- 004_seed.sql  --  predicates + hand-written test conversations
-- Belief times are set explicitly (memory.txn_time) so history is realistic.
-- =====================================================================
INSERT INTO predicates (name, is_single_valued, value_type, description) VALUES
  ('works_at',       true,  'entity', 'current employer'),
  ('lives_in',       true,  'entity', 'city of residence'),
  ('has_role',       true,  'text',   'job title'),
  ('favourite_food', true,  'text',   'favourite food'),
  ('likes',          false, 'text',   'things the person likes'),
  ('speaks',         false, 'entity', 'languages spoken'),
  ('skilled_in',     false, 'text',   'skills');

DO $$
DECLARE s bigint;
BEGIN
  -- ===== Conversation c1: Priya =====
  PERFORM set_config('memory.txn_time', '2026-03-10 10:00:00+05:30', false);
  s := log_source('c1', 1, 'user', 'I work at Infosys, joined in June last year, as a software engineer. Been in Bengaluru since 2023.', '2026-03-10 10:00:00+05:30');
  PERFORM remember('Priya', 'works_at', 'Infosys',   s, '2025-06-01 00:00:00+05:30', 0.95, p_object_type => 'org');
  PERFORM remember('Priya', 'has_role', 'Software Engineer', s, '2025-06-01 00:00:00+05:30', 0.95);
  PERFORM remember('Priya', 'lives_in', 'Bengaluru', s, '2023-01-01 00:00:00+05:30', 0.90, p_object_type => 'place');

  PERFORM set_config('memory.txn_time', '2026-03-10 10:05:00+05:30', false);
  s := log_source('c1', 2, 'user', 'I love filter coffee and badminton. I speak Kannada and English.', '2026-03-10 10:05:00+05:30');
  PERFORM remember('Priya', 'likes', 'filter coffee', s, '2026-03-10 10:05:00+05:30');
  PERFORM remember('Priya', 'likes', 'badminton',     s, '2026-03-10 10:05:00+05:30');
  PERFORM remember('Priya', 'speaks', 'Kannada',      s, '2026-03-10 10:05:00+05:30');
  PERFORM remember('Priya', 'speaks', 'English',      s, '2026-03-10 10:05:00+05:30');

  PERFORM set_config('memory.txn_time', '2026-04-02 18:00:00+05:30', false);
  s := log_source('c1', 3, 'user', 'I mostly code in Python and SQL.', '2026-04-02 18:00:00+05:30');
  PERFORM remember('Priya', 'skilled_in', 'Python', s, '2026-04-02 18:00:00+05:30');
  PERFORM remember('Priya', 'skilled_in', 'SQL',    s, '2026-04-02 18:00:00+05:30');

  PERFORM set_config('memory.txn_time', '2026-05-18 09:30:00+05:30', false);
  s := log_source('c1', 4, 'user', 'Got promoted to Senior Engineer last week!', '2026-05-18 09:30:00+05:30');
  PERFORM remember('Priya', 'has_role', 'Senior Engineer', s, '2026-05-11 00:00:00+05:30');

  PERFORM set_config('memory.txn_time', '2026-08-20 10:00:00+05:30', false);
  s := log_source('c1', 5, 'user', 'I just joined a startup, Zeta Labs, last week, as a founding engineer.', '2026-08-20 10:00:00+05:30');
  PERFORM remember('Priya', 'works_at', 'Zeta Labs', s, '2026-08-15 00:00:00+05:30', 0.90, p_object_type => 'org');
  PERFORM remember('Priya', 'has_role', 'Founding Engineer', s, '2026-08-15 00:00:00+05:30', 0.90);

  PERFORM set_config('memory.txn_time', '2026-08-20 10:30:00+05:30', false);
  s := log_source('c1', 6, 'user', 'Moved to Pune on Tuesday for the new job.', '2026-08-20 10:30:00+05:30');
  PERFORM remember('Priya', 'lives_in', 'Pune', s, '2026-08-18 00:00:00+05:30', 0.90, p_object_type => 'place');

  -- A CORRECTION: same object, earlier valid start. Old belief stays on record.
  PERFORM set_config('memory.txn_time', '2026-09-05 12:00:00+05:30', false);
  s := log_source('c1', 7, 'user', 'Sorry, I actually started at Zeta Labs on 1 August, not mid-August.', '2026-09-05 12:00:00+05:30');
  PERFORM remember('Priya', 'works_at', 'Zeta Labs', s, '2026-08-01 00:00:00+05:30', 0.95, p_object_type => 'org');

  -- ===== Conversation c2: Rohan =====
  PERFORM set_config('memory.txn_time', '2026-02-14 20:00:00+05:30', false);
  s := log_source('c2', 1, 'user', 'I live in Mysuru, work at TCS since July 2024. My favourite food is dosa. I like cricket.', '2026-02-14 20:00:00+05:30');
  PERFORM remember('Rohan', 'lives_in', 'Mysuru', s, '2020-01-01 00:00:00+05:30', 0.90, p_object_type => 'place');
  PERFORM remember('Rohan', 'works_at', 'TCS',    s, '2024-07-01 00:00:00+05:30', 0.95, p_object_type => 'org');
  PERFORM remember('Rohan', 'favourite_food', 'Dosa', s, '2026-02-14 20:00:00+05:30');
  PERFORM remember('Rohan', 'likes', 'cricket',   s, '2026-02-14 20:00:00+05:30');

  PERFORM set_config('memory.txn_time', '2026-07-02 19:00:00+05:30', false);
  s := log_source('c2', 2, 'user', 'These days my favourite food is biryani, honestly.', '2026-07-02 19:00:00+05:30');
  PERFORM remember('Rohan', 'favourite_food', 'Biryani', s, '2026-07-02 19:00:00+05:30');
END $$;

RESET memory.txn_time;
