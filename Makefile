ENV ?= dev

.PHONY: build lint params test what-if apply destroy fmt

build: ## Compile the entry point to ARM JSON in out/
	@mkdir -p out
	az bicep build --file infra/main.bicep --outfile out/main.json

lint: ## Lint every Bicep file; any warning fails
	scripts/lint.sh

params: ## Compile both parameter files
	@for e in dev prod; do az bicep build-params --file infra/params/$$e.bicepparam --stdout >/dev/null || exit 1; done; echo "params ok"

fmt: ## Format every Bicep file in place
	@find infra modules -name '*.bicep' -o -name '*.bicepparam' | xargs -n1 az bicep format --file

test: build ## Assert security properties on the compiled template
	python3 tests/test_template.py out/main.json

what-if: ## Preview changes against the current subscription
	scripts/deploy.sh $(ENV) what-if

apply: ## Create or update the deployment stack
	scripts/deploy.sh $(ENV) apply

destroy: ## Delete the deployment stack and everything it manages
	scripts/deploy.sh $(ENV) destroy
