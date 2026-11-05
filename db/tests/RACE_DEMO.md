# Race demo: two supervisors allocate 6,000 each from one 10,000 freeze

1. Rebuild the DB, then load the fixture:
   docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/race_setup.sql
   (freeze_id = 1, cases 1 and 2)

2. Open two PowerShell windows. In each run:
   docker compose exec postgres psql -U tracepay_owner -d tracepay

3. Type, in this order:

| Step | Terminal A                                   | Terminal B                                   |
|------|----------------------------------------------|----------------------------------------------|
| 1    | BEGIN;                                       | BEGIN;                                       |
| 2    | INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by) VALUES (1, 1, 6000, 9); |  |
| 3    |                                              | INSERT INTO recovery_allocations (freeze_id, case_id, amount, allocated_by) VALUES (1, 2, 6000, 9); -> HANGS (waiting for A's lock) |
| 4    | COMMIT;                                      | -> ERROR: invariant allocation_within_freeze violated, excess=2000.00 |
| 5    |                                              | ROLLBACK;                                    |

4. Check: SELECT freeze_id, case_id, amount FROM recovery_allocations;  -> one row, 6,000.

Why: the engine's BEFORE trigger locks the freeze row (SELECT ... FOR UPDATE). B waits; after A commits,
B's AFTER trigger recounts in a fresh snapshot, sees 6,000 + 6,000 > 10,000 and raises TP001.
Without the lock, both would read "10,000 free" and both would commit (12,000 promised from 10,000).
(user_id 9 = sup1@demo.in)
