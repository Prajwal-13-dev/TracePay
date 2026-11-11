-- 001_core.sql : extensions, types, status lookup tables, tables, keys and constraints.
-- Every rule that fits a single row is a named constraint here; rules across rows live in 002 (triggers)
-- and 003 (the constraint engine).
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TYPE user_role AS ENUM ('CUSTOMER', 'INVESTIGATOR', 'SUPERVISOR');

-- Status values live in lookup tables (one place for codes, labels and order) ------------------------
CREATE TABLE case_status (
  code       text PRIMARY KEY,
  label      text NOT NULL,
  sort_order smallint NOT NULL UNIQUE,
  is_open    boolean NOT NULL
);
INSERT INTO case_status VALUES
  ('SUBMITTED', 'Submitted', 1, true), ('UNDER_REVIEW', 'Under review', 2, true),
  ('INVESTIGATING', 'Investigating', 3, true), ('RECOVERY', 'Recovery', 4, true),
  ('CLOSED', 'Closed', 5, false), ('REJECTED', 'Rejected', 6, false);

CREATE TABLE freeze_status (
  code        text PRIMARY KEY,
  label       text NOT NULL,
  sort_order  smallint NOT NULL UNIQUE,
  holds_money boolean NOT NULL
);
INSERT INTO freeze_status VALUES
  ('REQUESTED', 'Requested', 1, false), ('DECLINED', 'Declined', 2, false), ('ACTIVE', 'Active', 3, true),
  ('RELEASED', 'Released', 4, false), ('EXPIRED', 'Expired', 5, false), ('SETTLED', 'Settled', 6, false);

CREATE TABLE allocation_status (code text PRIMARY KEY, label text NOT NULL, sort_order smallint NOT NULL UNIQUE);
INSERT INTO allocation_status VALUES ('ACTIVE', 'Active', 1), ('PAID', 'Paid', 2), ('CANCELLED', 'Cancelled', 3);

CREATE TABLE refund_status (code text PRIMARY KEY, label text NOT NULL, sort_order smallint NOT NULL UNIQUE);
INSERT INTO refund_status VALUES ('PROCESSED', 'Processed', 1);

-- People and money ------------------------------------------------------------------------------------
CREATE TABLE users (
  user_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email         citext NOT NULL,
  full_name     text NOT NULL,
  phone         varchar(15),
  password_hash text NOT NULL,
  role          user_role NOT NULL DEFAULT 'CUSTOMER',
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT users_email_key       UNIQUE (email),
  CONSTRAINT users_email_check     CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  CONSTRAINT users_full_name_check CHECK (length(btrim(full_name)) BETWEEN 2 AND 100),
  CONSTRAINT users_phone_check     CHECK (phone ~ '^[6-9][0-9]{9}$'),
  CONSTRAINT users_password_check  CHECK (password_hash ~ '^\$(2[aby]|argon2id)\$')
);

CREATE TABLE accounts (
  account_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     bigint NOT NULL REFERENCES users(user_id),
  account_ref text NOT NULL,
  ifsc        text DEFAULT 'TPAY0000001',            -- branch code; every TracePay account is in one branch
  balance     numeric(14,2) NOT NULL DEFAULT 0,
  status      text NOT NULL DEFAULT 'ACTIVE',
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT accounts_account_ref_key   UNIQUE (account_ref),
  CONSTRAINT accounts_account_ref_check CHECK (account_ref ~ '^TP[0-9]{10}$'),
  CONSTRAINT accounts_ifsc_format       CHECK (ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  CONSTRAINT accounts_balance_check     CHECK (balance >= 0),
  CONSTRAINT accounts_status_check      CHECK (status IN ('ACTIVE', 'CLOSED'))
);

-- A transfer is immutable once written (002). Inserting one moves the money (007, trigger apply_transfer).
-- RECOVERY = a refund paid from a frozen account to a victim (never traced, never disputable).
CREATE TABLE transactions (
  txn_id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  external_ref           text NOT NULL,
  source_account_id      bigint NOT NULL REFERENCES accounts(account_id),
  destination_account_id bigint NOT NULL REFERENCES accounts(account_id),
  amount                 numeric(14,2) NOT NULL,
  channel                text NOT NULL,
  occurred_at            timestamptz NOT NULL,
  CONSTRAINT transactions_external_ref_key UNIQUE (external_ref),
  CONSTRAINT transactions_amount_check     CHECK (amount > 0),
  CONSTRAINT transactions_channel_check    CHECK (channel IN ('UPI', 'IMPS', 'NEFT', 'CARD', 'RECOVERY')),
  CONSTRAINT transactions_not_to_self      CHECK (source_account_id <> destination_account_id)
);

-- Complaints and cases ------------------------------------------------------------------------------
-- A draft keeps every answer of the complaint wizard. Only the customer's own transfers (002, check_draft).
CREATE TABLE draft_complaints (
  draft_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id     bigint NOT NULL REFERENCES users(user_id),
  disputed_txn_id bigint REFERENCES transactions(txn_id),
  reported_amount numeric(14,2),
  scam_type       text,
  narrative       text NOT NULL DEFAULT '',
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT draft_complaints_reported_amount_check CHECK (reported_amount > 0),
  CONSTRAINT draft_complaints_scam_type_check       CHECK (length(scam_type) <= 60),
  CONSTRAINT draft_complaints_narrative_check       CHECK (length(narrative) <= 5000)
);

CREATE TABLE fraud_cases (
  case_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id        bigint NOT NULL REFERENCES users(user_id),
  disputed_txn_id    bigint NOT NULL REFERENCES transactions(txn_id),
  status             text NOT NULL DEFAULT 'SUBMITTED' REFERENCES case_status(code),
  priority           smallint NOT NULL DEFAULT 2,
  reported_amount    numeric(14,2) NOT NULL,
  verified_loss      numeric(14,2),
  verified_by        bigint REFERENCES users(user_id),
  narrative          text NOT NULL,
  investigator_notes text,
  search_vector      tsvector GENERATED ALWAYS AS (
                       setweight(to_tsvector('english', narrative), 'A') ||
                       setweight(to_tsvector('english', coalesce(investigator_notes, '')), 'B')
                     ) STORED,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fraud_cases_disputed_txn_id_key    UNIQUE (disputed_txn_id),     -- one case per transfer
  CONSTRAINT fraud_cases_priority_check         CHECK (priority BETWEEN 1 AND 5),
  CONSTRAINT fraud_cases_reported_amount_check  CHECK (reported_amount > 0),
  CONSTRAINT fraud_cases_verified_loss_check    CHECK (verified_loss > 0 AND verified_loss <= reported_amount),
  CONSTRAINT fraud_cases_verified_pair          CHECK ((verified_loss IS NULL) = (verified_by IS NULL)),
  CONSTRAINT fraud_cases_narrative_check        CHECK (length(narrative) BETWEEN 30 AND 5000)
);

-- The case state machine: allowed moves are data; trigger enforce_case_transition (002) enforces them.
CREATE TABLE case_status_transitions (
  from_status  text NOT NULL REFERENCES case_status(code),
  to_status    text NOT NULL REFERENCES case_status(code),
  allowed_role user_role NOT NULL,
  PRIMARY KEY (from_status, to_status, allowed_role),
  CONSTRAINT case_status_transitions_check CHECK (from_status <> to_status)
);

-- The customer-facing timeline (audit_log is the full record). note = message shown to the customer.
CREATE TABLE case_status_history (
  history_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_id     bigint NOT NULL REFERENCES fraud_cases(case_id),
  from_status text NOT NULL REFERENCES case_status(code),
  to_status   text NOT NULL REFERENCES case_status(code),
  changed_by  bigint REFERENCES users(user_id),
  changed_at  timestamptz NOT NULL DEFAULT now(),
  note        text,
  CONSTRAINT case_status_history_note_check CHECK (length(note) <= 1000)
);

CREATE TABLE case_assignments (
  assignment_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_id         bigint NOT NULL REFERENCES fraud_cases(case_id),
  investigator_id bigint NOT NULL REFERENCES users(user_id),
  assigned_by     bigint NOT NULL REFERENCES users(user_id),
  assigned_at     timestamptz NOT NULL DEFAULT now(),
  ended_at        timestamptz,
  CONSTRAINT case_assignments_check CHECK (ended_at IS NULL OR ended_at > assigned_at)
);
CREATE UNIQUE INDEX one_open_assignment ON case_assignments (case_id) WHERE ended_at IS NULL;

-- Tracing -------------------------------------------------------------------------------------------
-- A node = a transfer confirmed as carrying this case's money, with how much of it (inflow).
CREATE TABLE trace_nodes (
  node_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_id       bigint NOT NULL REFERENCES fraud_cases(case_id),
  txn_id        bigint NOT NULL REFERENCES transactions(txn_id),
  is_root       boolean NOT NULL DEFAULT false,
  inflow_amount numeric(14,2) NOT NULL,
  CONSTRAINT trace_nodes_case_id_txn_id_key UNIQUE (case_id, txn_id),   -- a transfer once per case
  CONSTRAINT trace_nodes_inflow_amount_check CHECK (inflow_amount > 0)
);
CREATE UNIQUE INDEX one_root_per_case ON trace_nodes (case_id) WHERE is_root;

-- Both ends of a link belong to the link's case (trigger check_link_case, 002).
CREATE TABLE fund_flow_links (
  link_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_id           bigint NOT NULL REFERENCES fraud_cases(case_id),
  from_node_id      bigint NOT NULL REFERENCES trace_nodes(node_id),
  to_node_id        bigint NOT NULL REFERENCES trace_nodes(node_id),
  attributed_amount numeric(14,2) NOT NULL,
  method            text NOT NULL,
  linked_by         bigint NOT NULL REFERENCES users(user_id),
  linked_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fund_flow_links_from_node_id_to_node_id_key UNIQUE (from_node_id, to_node_id),
  CONSTRAINT fund_flow_links_attributed_amount_check     CHECK (attributed_amount > 0),
  CONSTRAINT fund_flow_links_method_check                CHECK (method IN ('MANUAL', 'FIFO')),
  CONSTRAINT fund_flow_links_check                       CHECK (from_node_id <> to_node_id)
);

-- Recovery ------------------------------------------------------------------------------------------
CREATE TABLE account_freezes (
  freeze_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id         bigint NOT NULL REFERENCES accounts(account_id),
  requested_for_case bigint NOT NULL REFERENCES fraud_cases(case_id),
  requested_by       bigint NOT NULL REFERENCES users(user_id),
  approved_by        bigint REFERENCES users(user_id),
  frozen_amount      numeric(14,2) NOT NULL,
  status             text NOT NULL DEFAULT 'REQUESTED' REFERENCES freeze_status(code),
  requested_at       timestamptz NOT NULL DEFAULT now(),
  approved_at        timestamptz,
  expires_at         timestamptz,
  CONSTRAINT account_freezes_frozen_amount_check CHECK (frozen_amount > 0),
  CONSTRAINT account_freezes_decided             CHECK (status = 'REQUESTED' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
  CONSTRAINT account_freezes_expiry              CHECK (status IN ('REQUESTED', 'DECLINED') OR expires_at > approved_at),
  CONSTRAINT account_freezes_four_eyes           CHECK (approved_by IS NULL OR approved_by <> requested_by)
);

CREATE TABLE recovery_allocations (
  allocation_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  freeze_id     bigint NOT NULL REFERENCES account_freezes(freeze_id),
  case_id       bigint NOT NULL REFERENCES fraud_cases(case_id),
  amount        numeric(14,2) NOT NULL,
  status        text NOT NULL DEFAULT 'ACTIVE' REFERENCES allocation_status(code),
  allocated_by  bigint NOT NULL REFERENCES users(user_id),
  allocated_at  timestamptz NOT NULL DEFAULT now(),
  credit_txn_id bigint REFERENCES transactions(txn_id),   -- the RECOVERY transfer that paid the victim
  CONSTRAINT recovery_allocations_amount_check     CHECK (amount > 0),
  CONSTRAINT recovery_allocations_credit_txn_id_key UNIQUE (credit_txn_id)
);
CREATE UNIQUE INDEX one_live_allocation ON recovery_allocations (freeze_id, case_id) WHERE status = 'ACTIVE';

CREATE TABLE refunds (
  refund_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  allocation_id   bigint NOT NULL REFERENCES recovery_allocations(allocation_id),
  amount          numeric(14,2) NOT NULL,
  status          text NOT NULL DEFAULT 'PROCESSED' REFERENCES refund_status(code),
  idempotency_key uuid NOT NULL,
  processed_by    bigint NOT NULL REFERENCES users(user_id),
  processed_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT refunds_amount_check          CHECK (amount > 0),
  CONSTRAINT refunds_idempotency_key_key   UNIQUE (idempotency_key)
);

-- Search and audit ----------------------------------------------------------------------------------
CREATE TABLE case_embeddings (
  case_id     bigint PRIMARY KEY REFERENCES fraud_cases(case_id),
  model       text NOT NULL DEFAULT 'Xenova/all-MiniLM-L6-v2',
  embedding   vector(384) NOT NULL,
  source_hash char(64) NOT NULL,
  embedded_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (
  audit_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id    bigint REFERENCES users(user_id),
  entity_type text NOT NULL,
  entity_id   bigint NOT NULL,
  action      text NOT NULL,
  old_row     jsonb,
  new_row     jsonb,
  at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT audit_log_action_check CHECK (action IN ('INSERT', 'UPDATE', 'DELETE'))
);
