# Race demo: two supervisors allocate 6,000 each from one 10,000 freeze

1. Rebuild the database (README), then load the fixture:

       docker compose exec postgres psql -U tracepay_owner -d tracepay -f /db/tests/race_demo_setup.sql

   It creates cases for T1 and T6 (each verified at 8,000) and a 10,000 freeze on account D, then prints
   **two INSERT lines**. Only the freeze limit can stop the second allocation.

2. Open two PowerShell windows. In each:

       cd C:\dev\TracePay
       docker compose exec postgres psql -U tracepay_owner -d tracepay

3. Type in this order:

| Step | Terminal A | Terminal B |
|------|------------|------------|
| 1 | `BEGIN;` | `BEGIN;` |
| 2 | paste the **first** INSERT line | |
| 3 | | paste the **second** INSERT line → it **hangs** (waiting for A's lock) |
| 4 | `COMMIT;` | → `ERROR: invariant allocation_within_freeze violated` ... `excess=2000.00` |
| 5 | | `ROLLBACK;` |

4. Check in either terminal: `SELECT freeze_id, case_id, amount FROM recovery_allocations;` shows one 6,000 row.

**Why:** the engine's BEFORE trigger locks the freeze row (`SELECT ... FOR UPDATE`). B waits; when A commits,
B's AFTER trigger recounts in a fresh snapshot, sees 6,000 + 6,000 > 10,000 and raises TP001.
Without the lock, both would read "10,000 free" and both would commit: 12,000 promised from 10,000.

The fixture commits data, so rebuild the database before the full app demo.
