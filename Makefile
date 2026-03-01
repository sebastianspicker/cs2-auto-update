# Same order as CI pipeline (lint, test, security).
.PHONY: lint fmt test security ci

lint:
	./scripts/lint.sh

fmt:
	./scripts/fmt.sh

test:
	./tests/run.sh

security:
	./scripts/security.sh

ci: lint test security
