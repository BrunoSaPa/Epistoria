.PHONY: bootstrap infra-up infra-down api-dev api-test api-test-e2e worker-install worker-test worker-doctor worker-service-install worker-service-uninstall worker-service-status ios-project ios-test verify security-scan public-docs-check backup backup-scheduled backup-prune backup-mirror-verify restore-check operations-test

bootstrap:
	npm ci --strict-allow-scripts
	./scripts/install-worker.sh

infra-up:
	docker compose -f infra/docker-compose.yml up -d --wait

infra-down:
	docker compose -f infra/docker-compose.yml down

api-dev:
	npm run dev

api-test:
	npm run test

api-test-e2e:
	./scripts/test-api-e2e.sh

worker-install:
	./scripts/install-worker.sh

worker-test:
	services/worker/.venv/bin/pytest services/worker/tests

worker-doctor:
	./scripts/run-worker.sh doctor

worker-service-install:
	./scripts/worker-service.sh install

worker-service-uninstall:
	./scripts/worker-service.sh uninstall

worker-service-status:
	./scripts/worker-service.sh status

ios-project:
	./scripts/generate-ios-project.sh

ios-test:
	cd apps/ios/EpistoriaCore && swift test

verify:
	./scripts/verify.sh

security-scan:
	./scripts/scan-secrets.sh

public-docs-check:
	node scripts/check-public-docs.mjs

backup:
	./scripts/backup.sh

backup-scheduled:
	./scripts/scheduled-backup.sh

backup-prune:
	./scripts/prune-backups.sh

backup-mirror-verify:
	./scripts/verify-object-mirror.sh

restore-check:
	./scripts/restore-check.sh

operations-test:
	./scripts/test-operations.sh
