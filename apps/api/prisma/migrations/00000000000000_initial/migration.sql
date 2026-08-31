-- CreateSchema
CREATE SCHEMA IF NOT EXISTS "public";

-- CreateEnum
CREATE TYPE "DeviceKind" AS ENUM ('IPAD', 'MAC');

-- CreateEnum
CREATE TYPE "EntityType" AS ENUM ('AREA', 'TOPIC_AREA', 'LIST', 'LIST_ITEM', 'TOPIC', 'STUDY_SESSION', 'NOTE', 'NOTE_PAGE', 'NOTE_BLOCK', 'TRASH_ENTRY', 'SOURCE', 'ASSET', 'ANNOTATION', 'SESSION_NOTE', 'SESSION_SOURCE', 'AI_ARTIFACT', 'RECOGNITION_ARTIFACT', 'RECOGNITION_DECISION', 'TRANSCRIPT_CORRECTION', 'SOURCE_VERSION', 'EVIDENCE', 'CONCEPT', 'CONCEPT_EVIDENCE', 'CONCEPT_LINK', 'KNOWLEDGE_MAP', 'STUDY_GOAL', 'UNRESOLVED_QUESTION', 'SESSION_ACTIVITY', 'FLASHCARD_DECK', 'FLASHCARD', 'FLASHCARD_REVISION', 'FLASHCARD_REVIEW', 'TOPIC_SCOPE_SNAPSHOT', 'TEST_BLUEPRINT', 'PRACTICE_TEST', 'TEST_QUESTION', 'TEST_ATTEMPT', 'TEST_RESPONSE', 'DAILY_REVIEW_RESPONSE', 'STUDY_RECOMMENDATION', 'RECOMMENDATION_RESPONSE', 'AUTOMATION_GRANT', 'TUTOR_SESSION', 'TUTOR_TURN', 'LEARNING_SIGNAL');

-- CreateEnum
CREATE TYPE "MutationOperation" AS ENUM ('UPSERT', 'DELETE');

-- CreateEnum
CREATE TYPE "MutationStatus" AS ENUM ('ACCEPTED', 'CONFLICT');

-- CreateEnum
CREATE TYPE "AssetState" AS ENUM ('PREPARED', 'AVAILABLE');

-- CreateEnum
CREATE TYPE "AIJobType" AS ENUM ('SESSION_DIGEST', 'PDF_EXTRACTION', 'NOTE_QUERY', 'MATH_ASSISTANCE', 'SOURCE_ANALYSIS', 'SOURCE_QUERY', 'SOURCE_EXTRACTION', 'TRANSCRIPTION', 'TOPIC_SYNTHESIS', 'FLASHCARD_DRAFTS', 'TEST_BLUEPRINT', 'TEST_GENERATION', 'FREE_RESPONSE_FEEDBACK', 'CONCEPT_SUGGESTIONS', 'SOURCE_DISCOVERY', 'SESSION_REVIEW', 'WEEKLY_REVIEW', 'PROVIDER_CONFIGURATION', 'TUTOR_TURN', 'LOCAL_OCR', 'LOCAL_MODEL_CONTROL');

-- CreateEnum
CREATE TYPE "AIJobStatus" AS ENUM ('PENDING', 'LEASED', 'COMPLETE', 'FAILED', 'CANCELLED');

-- CreateTable
CREATE TABLE "users" (
    "id" UUID NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "users_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "devices" (
    "id" UUID NOT NULL,
    "owner_id" UUID NOT NULL,
    "kind" "DeviceKind" NOT NULL,
    "token_hash" VARCHAR(64) NOT NULL,
    "display_name_sealed" BYTEA,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "last_seen_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "revoked_at" TIMESTAMP(3),

    CONSTRAINT "devices_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "entity_envelopes" (
    "id" UUID NOT NULL,
    "owner_id" UUID NOT NULL,
    "entity_type" "EntityType" NOT NULL,
    "parent_id" UUID,
    "relation_ids" UUID[] DEFAULT ARRAY[]::UUID[],
    "revision" INTEGER NOT NULL,
    "tombstone" BOOLEAN NOT NULL DEFAULT false,
    "crypto_version" INTEGER NOT NULL,
    "content_version" INTEGER NOT NULL,
    "sealed_dek" BYTEA NOT NULL,
    "sealed_content" BYTEA NOT NULL,
    "dedupe_tag" VARCHAR(64),
    "payload_size" INTEGER NOT NULL,
    "client_modified_at" TIMESTAMP(3) NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "entity_envelopes_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "change_log" (
    "sequence" BIGSERIAL NOT NULL,
    "owner_id" UUID NOT NULL,
    "device_id" UUID NOT NULL,
    "mutation_id" UUID NOT NULL,
    "entity_id" UUID NOT NULL,
    "entity_type" "EntityType" NOT NULL,
    "operation" "MutationOperation" NOT NULL,
    "revision" INTEGER NOT NULL,
    "parent_id" UUID,
    "relation_ids" UUID[] DEFAULT ARRAY[]::UUID[],
    "crypto_version" INTEGER NOT NULL,
    "content_version" INTEGER NOT NULL,
    "sealed_dek" BYTEA NOT NULL,
    "sealed_content" BYTEA NOT NULL,
    "dedupe_tag" VARCHAR(64),
    "payload_size" INTEGER NOT NULL,
    "client_modified_at" TIMESTAMP(3) NOT NULL,
    "changed_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "change_log_pkey" PRIMARY KEY ("sequence")
);

-- CreateTable
CREATE TABLE "mutation_receipts" (
    "id" UUID NOT NULL,
    "owner_id" UUID NOT NULL,
    "device_id" UUID NOT NULL,
    "mutation_id" UUID NOT NULL,
    "entity_id" UUID NOT NULL,
    "status" "MutationStatus" NOT NULL,
    "revision" INTEGER,
    "sequence" BIGINT,
    "conflict_id" UUID,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "mutation_receipts_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "conflict_candidates" (
    "id" UUID NOT NULL,
    "owner_id" UUID NOT NULL,
    "device_id" UUID NOT NULL,
    "mutation_id" UUID NOT NULL,
    "entity_id" UUID NOT NULL,
    "entity_type" "EntityType" NOT NULL,
    "operation" "MutationOperation" NOT NULL,
    "base_revision" INTEGER NOT NULL,
    "current_revision" INTEGER NOT NULL,
    "parent_id" UUID,
    "relation_ids" UUID[] DEFAULT ARRAY[]::UUID[],
    "crypto_version" INTEGER NOT NULL,
    "content_version" INTEGER NOT NULL,
    "sealed_dek" BYTEA NOT NULL,
    "sealed_content" BYTEA NOT NULL,
    "dedupe_tag" VARCHAR(64),
    "payload_size" INTEGER NOT NULL,
    "client_modified_at" TIMESTAMP(3) NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "resolved_at" TIMESTAMP(3),

    CONSTRAINT "conflict_candidates_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "asset_objects" (
    "id" UUID NOT NULL,
    "owner_id" UUID NOT NULL,
    "dedupe_tag" VARCHAR(64) NOT NULL,
    "object_key" TEXT NOT NULL,
    "byte_size" BIGINT NOT NULL,
    "state" "AssetState" NOT NULL DEFAULT 'PREPARED',
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "available_at" TIMESTAMP(3),

    CONSTRAINT "asset_objects_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ai_jobs" (
    "id" UUID NOT NULL,
    "owner_id" UUID NOT NULL,
    "requested_by_device_id" UUID NOT NULL,
    "job_type" "AIJobType" NOT NULL,
    "status" "AIJobStatus" NOT NULL DEFAULT 'PENDING',
    "crypto_version" INTEGER NOT NULL,
    "content_version" INTEGER NOT NULL,
    "sealed_dek" BYTEA NOT NULL,
    "sealed_payload" BYTEA NOT NULL,
    "payload_size" INTEGER NOT NULL,
    "leased_by_device_id" UUID,
    "lease_expires_at" TIMESTAMP(3),
    "attempts" INTEGER NOT NULL DEFAULT 0,
    "artifact_entity_id" UUID,
    "error_code" VARCHAR(64),
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,
    "completed_at" TIMESTAMP(3),

    CONSTRAINT "ai_jobs_pkey" PRIMARY KEY ("id")
);

-- Defense-in-depth constraints mirror the wire validators. They protect invariants even
-- when maintenance scripts or a future API version write directly to PostgreSQL.
ALTER TABLE "devices"
  ADD CONSTRAINT "devices_token_hash_shape" CHECK ("token_hash" ~ '^[0-9a-f]{64}$');

ALTER TABLE "entity_envelopes"
  ALTER COLUMN "relation_ids" SET NOT NULL,
  ADD CONSTRAINT "entity_envelopes_revision_positive" CHECK ("revision" >= 1),
  ADD CONSTRAINT "entity_envelopes_crypto_version" CHECK ("crypto_version" BETWEEN 1 AND 255),
  ADD CONSTRAINT "entity_envelopes_content_version" CHECK ("content_version" BETWEEN 1 AND 65535),
  ADD CONSTRAINT "entity_envelopes_dek_size" CHECK (octet_length("sealed_dek") = 72),
  ADD CONSTRAINT "entity_envelopes_payload_size" CHECK ("payload_size" BETWEEN 0 AND 2097152),
  ADD CONSTRAINT "entity_envelopes_content_size" CHECK (octet_length("sealed_content") = "payload_size" + 40),
  ADD CONSTRAINT "entity_envelopes_relation_count" CHECK (cardinality("relation_ids") <= 64),
  ADD CONSTRAINT "entity_envelopes_dedupe_shape" CHECK ("dedupe_tag" IS NULL OR "dedupe_tag" ~ '^[0-9a-f]{64}$');

ALTER TABLE "change_log"
  ALTER COLUMN "relation_ids" SET NOT NULL,
  ADD CONSTRAINT "change_log_revision_positive" CHECK ("revision" >= 1),
  ADD CONSTRAINT "change_log_dek_size" CHECK (octet_length("sealed_dek") = 72),
  ADD CONSTRAINT "change_log_content_size" CHECK (octet_length("sealed_content") = "payload_size" + 40),
  ADD CONSTRAINT "change_log_relation_count" CHECK (cardinality("relation_ids") <= 64);

ALTER TABLE "conflict_candidates"
  ALTER COLUMN "relation_ids" SET NOT NULL,
  ADD CONSTRAINT "conflict_candidates_revisions" CHECK ("base_revision" >= 0 AND "current_revision" >= 0),
  ADD CONSTRAINT "conflict_candidates_dek_size" CHECK (octet_length("sealed_dek") = 72),
  ADD CONSTRAINT "conflict_candidates_content_size" CHECK (octet_length("sealed_content") = "payload_size" + 40),
  ADD CONSTRAINT "conflict_candidates_relation_count" CHECK (cardinality("relation_ids") <= 64);

ALTER TABLE "asset_objects"
  ADD CONSTRAINT "asset_objects_dedupe_shape" CHECK ("dedupe_tag" ~ '^[0-9a-f]{64}$'),
  ADD CONSTRAINT "asset_objects_size" CHECK ("byte_size" BETWEEN 1 AND 536870912);

ALTER TABLE "ai_jobs"
  ADD CONSTRAINT "ai_jobs_dek_size" CHECK (octet_length("sealed_dek") = 72),
  ADD CONSTRAINT "ai_jobs_payload_size" CHECK ("payload_size" BETWEEN 1 AND 1048576),
  ADD CONSTRAINT "ai_jobs_content_size" CHECK (octet_length("sealed_payload") = "payload_size" + 40),
  ADD CONSTRAINT "ai_jobs_attempts" CHECK ("attempts" BETWEEN 0 AND 5),
  ADD CONSTRAINT "ai_jobs_error_code_shape" CHECK ("error_code" IS NULL OR "error_code" ~ '^[A-Z0-9_]{1,64}$');

-- CreateIndex
CREATE UNIQUE INDEX "devices_token_hash_key" ON "devices"("token_hash");

-- CreateIndex
CREATE INDEX "devices_owner_id_revoked_at_idx" ON "devices"("owner_id", "revoked_at");

-- CreateIndex
CREATE INDEX "entity_envelopes_owner_id_entity_type_updated_at_idx" ON "entity_envelopes"("owner_id", "entity_type", "updated_at");

-- CreateIndex
CREATE INDEX "entity_envelopes_owner_id_parent_id_idx" ON "entity_envelopes"("owner_id", "parent_id");

-- CreateIndex
CREATE INDEX "change_log_owner_id_sequence_idx" ON "change_log"("owner_id", "sequence");

-- CreateIndex
CREATE INDEX "change_log_owner_id_entity_id_revision_idx" ON "change_log"("owner_id", "entity_id", "revision");

-- CreateIndex
CREATE UNIQUE INDEX "change_log_owner_id_mutation_id_key" ON "change_log"("owner_id", "mutation_id");

-- CreateIndex
CREATE INDEX "mutation_receipts_owner_id_device_id_created_at_idx" ON "mutation_receipts"("owner_id", "device_id", "created_at");

-- CreateIndex
CREATE UNIQUE INDEX "mutation_receipts_owner_id_mutation_id_key" ON "mutation_receipts"("owner_id", "mutation_id");

-- CreateIndex
CREATE INDEX "conflict_candidates_owner_id_device_id_resolved_at_idx" ON "conflict_candidates"("owner_id", "device_id", "resolved_at");

-- CreateIndex
CREATE UNIQUE INDEX "conflict_candidates_owner_id_mutation_id_key" ON "conflict_candidates"("owner_id", "mutation_id");

-- CreateIndex
CREATE UNIQUE INDEX "asset_objects_object_key_key" ON "asset_objects"("object_key");

-- CreateIndex
CREATE INDEX "asset_objects_owner_id_state_idx" ON "asset_objects"("owner_id", "state");

-- CreateIndex
CREATE UNIQUE INDEX "asset_objects_owner_id_dedupe_tag_key" ON "asset_objects"("owner_id", "dedupe_tag");

-- CreateIndex
CREATE INDEX "ai_jobs_owner_id_status_created_at_idx" ON "ai_jobs"("owner_id", "status", "created_at");

-- CreateIndex
CREATE INDEX "ai_jobs_lease_expires_at_idx" ON "ai_jobs"("lease_expires_at");

-- AddForeignKey
ALTER TABLE "devices" ADD CONSTRAINT "devices_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "entity_envelopes" ADD CONSTRAINT "entity_envelopes_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "change_log" ADD CONSTRAINT "change_log_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "change_log" ADD CONSTRAINT "change_log_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "devices"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "mutation_receipts" ADD CONSTRAINT "mutation_receipts_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "mutation_receipts" ADD CONSTRAINT "mutation_receipts_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "devices"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "conflict_candidates" ADD CONSTRAINT "conflict_candidates_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "conflict_candidates" ADD CONSTRAINT "conflict_candidates_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "devices"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "asset_objects" ADD CONSTRAINT "asset_objects_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ai_jobs" ADD CONSTRAINT "ai_jobs_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ai_jobs" ADD CONSTRAINT "ai_jobs_requested_by_device_id_fkey" FOREIGN KEY ("requested_by_device_id") REFERENCES "devices"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ai_jobs" ADD CONSTRAINT "ai_jobs_leased_by_device_id_fkey" FOREIGN KEY ("leased_by_device_id") REFERENCES "devices"("id") ON DELETE SET NULL ON UPDATE CASCADE;
