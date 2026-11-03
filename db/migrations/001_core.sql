-- 001_core.sql : extensions, types, tables, keys, constraints (handbook Appendix A.1)
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TYPE user_role AS ENUM ('CUSTOMER', 'INVESTIGATOR', 'SUPERVISOR');

CREATE TABLE users (
  user_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email         citext NOT NULL UNIQUE CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  full_name     text NOT NULL CHECK (length(btrim(full_name)) BETWEEN 2 AND 100),
  phone         text CHECK (phone ~ '^[6-9][0-9]{9}$'),
  password_hash text NOT NULL CHECK (password_hash ~ '^\$(2[aby]|argon2id)\$'),
  role          user_role NOT NULL DEFAULT 'CUSTOMER',
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE accounts (
  account_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     bigint NOT NULL REFERENCES users(user_id),
  account_ref text NOT NULL UNIQUE CHECK (account_ref ~ '^TP[0-9]{10}$'),
  balance     numeric(14,2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
  status      text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'CLOSED')),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE transactions (
  txn_id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  external_ref           text NOT NULL UNIQUE,
  source_account_id      bigint NOT NULL REFERENCES accounts(account_id),
  destination_account_id bigint NOT NULL REFERENCES accounts(account_id),
  amount                 numeric(14,2) NOT NULL CHECK (amount > 0),
  channel                text NOT NULL CHECK (channel IN ('UPI', 'IMPS', 'NEFT', 'CARD')),
  occurred_at            timestamptz NOT NULL,
  CHECK (source_account_id <> destination_account_id)
);

CREATE TABLE draft_complaints (
  draft_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id     bigint NOT NULL REFERENCES users(user_id),
  disputed_txn_id bigint REFERENCES transactions(txn_id),
  narrative       text NOT NULL DEFAULT '' CHECK (length(narrative) <= 5000),
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE fraud_cases (
  case_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id        bigint NOT NULL REFERENCES users(user_id),
  disputed_txn_id    bigint NOT NULL UNIQUE REFERENCES transactions(txn_id),
  status             text NOT NULL DEFAULT 'SUBMITTED'
                     CHECK (status IN ('SUBMITTED', 'UNDER_REVIEW', 'INVESTIGATING',
                                       'RECOVERY', 'CLOSED', 'REJECTED')),
  priority           smallint NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
  reported_amount    numeric(14,2) NOT NULL CHECK (reported_amount > 0),
  verified_loss      numeric(14,2) CHECK (verified_loss > 0 AND verified_loss <= reported_amount),
  verified_by        bigint REFERENCES users(user_id),
  narrative          text NOT NULL CHECK (length(narrative) BETWEEN 30 AND 5000),
  investigator_notes text,
  search_vector      tsvector GENERATED ALWAYS AS (
                       setweight(to_tsvector('english', narrative), 'A') ||
                       setweight(to_tsvector('english', coalesce(investigator_notes, '')), 'B')
                     ) STORED,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CHECK ((verified_loss IS NULL) = (verified_by IS NULL))
);

CREATE TABLE case_status_transitions (
  from_status  text NOT NULL,
  to_status    text NOT NULL,
  allowed_role user_role NOT NULL,
  PRIMARY KEY (from_status, to_status, allowed_role),
  CHECK (from_status <> to_status)
);

CREATE TABLE case_status_history (
  history_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_id     bigint NOT NULL REFERENCES fraud_cases(case_id),
  from_status text NOT NULL,
  to_status   text NOT NULL,
  changed_by  bigint REFERENCES users(user_id),
  changed_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE case_assignments (
  case_id         bigint NOT NULL REFERENCES fraud_cases(case_id),
  investigator_id bigint NOT NULL REFERENCES users(user_id),
  assigned_by     bigint NOT NULL REFERENCES users(user_id),
  assigned_at     timestamptz NOT NULL DEFAULT now(),
  ended_at        timestamptz,
  PRIMARY KEY (case_id, investigator_id, assigned_at),
  CHECK (ended_at IS NULL OR ended_at > assigned_at)
);
CREATE UNIQUE INDEX one_open_assignment ON case_assignments (case_id) WHERE ended_at IS NULL;

CREATE TABLE trace_nodes (
  node_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_id       bigint NOT NULL REFERENCES fraud_cases(case_id),
  txn_id        bigint NOT NULL REFERENCES transactions(txn_id),
  is_root       boolean NOT NULL DEFAULT false,
  inflow_amount numeric(14,2) NOT NULL CHECK (inflow_amount > 0),
  UNIQUE (case_id, txn_id),
  UNIQUE (case_id, node_id)            -- target of the composite FKs below
);
CREATE UNIQUE INDEX one_root_per_case ON trace_nodes (case_id) WHERE is_root;

CREATE TABLE fund_flow_links (
  link_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_id           bigint NOT NULL,
  from_node_id      bigint NOT NULL,
  to_node_id        bigint NOT NULL,
  attributed_amount numeric(14,2) NOT NULL CHECK (attributed_amount > 0),
  method            text NOT NULL CHECK (method IN ('MANUAL', 'FIFO', 'PROPORTIONAL')),
  linked_by         bigint NOT NULL REFERENCES users(user_id),
  linked_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (from_node_id <> to_node_id),
  UNIQUE (from_node_id, to_node_id),
  FOREIGN KEY (case_id, from_node_id) REFERENCES trace_nodes (case_id, node_id),
  FOREIGN KEY (case_id, to_node_id)   REFERENCES trace_nodes (case_id, node_id)
);

CREATE TABLE account_freezes (
  freeze_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id         bigint NOT NULL REFERENCES accounts(account_id),
  requested_for_case bigint NOT NULL REFERENCES fraud_cases(case_id),
  requested_by       bigint NOT NULL REFERENCES users(user_id),
  approved_by        bigint REFERENCES users(user_id),
  frozen_amount      numeric(14,2) NOT NULL CHECK (frozen_amount > 0),
  status             text NOT NULL DEFAULT 'REQUESTED'
                     CHECK (status IN ('REQUESTED', 'DECLINED', 'ACTIVE',
                                       'RELEASED', 'EXPIRED', 'SETTLED')),
  requested_at       timestamptz NOT NULL DEFAULT now(),
  approved_at        timestamptz,
  expires_at         timestamptz,
  CHECK (status = 'REQUESTED' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
  CHECK (status IN ('REQUESTED', 'DECLINED') OR expires_at > approved_at),
  CHECK (approved_by IS NULL OR approved_by <> requested_by)   -- four-eyes rule
);

CREATE TABLE recovery_allocations (
  allocation_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  freeze_id     bigint NOT NULL REFERENCES account_freezes(freeze_id),
  case_id       bigint NOT NULL REFERENCES fraud_cases(case_id),
  amount        numeric(14,2) NOT NULL CHECK (amount > 0),
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'PAID', 'CANCELLED')),
  allocated_by  bigint NOT NULL REFERENCES users(user_id),
  allocated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX one_live_allocation ON recovery_allocations (freeze_id, case_id)
  WHERE status = 'ACTIVE';

CREATE TABLE refunds (
  refund_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  allocation_id   bigint NOT NULL REFERENCES recovery_allocations(allocation_id),
  amount          numeric(14,2) NOT NULL CHECK (amount > 0),
  status          text NOT NULL DEFAULT 'PROCESSED' CHECK (status IN ('PROCESSED', 'REVERSED')),
  idempotency_key uuid NOT NULL UNIQUE,
  processed_by    bigint NOT NULL REFERENCES users(user_id),
  processed_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE case_evidence_refs (
  evidence_ref_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_id           bigint NOT NULL REFERENCES fraud_cases(case_id),
  mongo_document_id char(24) NOT NULL UNIQUE CHECK (mongo_document_id ~ '^[0-9a-f]{24}$'),
  evidence_type     text NOT NULL CHECK (evidence_type IN ('SCREENSHOT', 'BANK_STATEMENT',
                                                           'CHAT_EXPORT', 'CALL_RECORDING', 'OTHER')),
  sha256            char(64) NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  uploaded_by       bigint NOT NULL REFERENCES users(user_id),
  uploaded_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (case_id, sha256)
);

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
  action      text NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
  old_row     jsonb,
  new_row     jsonb,
  at          timestamptz NOT NULL DEFAULT now()
);
