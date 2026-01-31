.PHONY: lint fmt test ci

lint:
	./scripts/lint.sh

fmt:
	./scripts/fmt.sh

test:
	./tests/run.sh

ci: lint test

