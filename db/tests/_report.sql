-- Prints the results of a test file and rolls everything back.
\o
\set QUIET off
SELECT line AS result FROM results ORDER BY n;
ROLLBACK;
