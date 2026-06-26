-- IO-107 Lab 5 — EXPAND migration (the guardrail step).
--
-- Add the `priority` column as NULLABLE and additive. v1 (blue) is completely
-- unaware of it and keeps reading/writing exactly as before; v2 (green) starts
-- using it. Because the change only ADDS, blue and green can hit the same
-- database at the same time during the rollout with zero errors.
--
-- This is the safe half of expand/contract. A *breaking* change here (renaming
-- or dropping a column v1 still selects) would have broken blue the instant
-- green migrated — which is exactly why zero-downtime Blue/Green over a shared
-- DB requires backward-compatible schema changes.

ALTER TABLE items ADD COLUMN IF NOT EXISTS priority INT;
