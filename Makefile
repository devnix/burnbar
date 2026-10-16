# Local mirror of .github/workflows/tests.yml — the workflow runs these same
# targets. `make` (= `make ci`) passing locally means the Linux jobs pass.
# The macOS job (stock /bin/bash 3.2, BSD userland) needs a Mac:
#   make perf PERF_BASH=/bin/bash
# Kept GNU make 3.81-compatible (the version macOS ships): no .SHELLFLAGS.

SHELL := /bin/bash
.DEFAULT_GOAL := ci

SHELLCHECK_IMAGE := koalaman/shellcheck:v0.11.0
ACTIONLINT_IMAGE := rhysd/actionlint:1.7.12
BASH32_IMAGE     := bash:3.2
SH_FILES         := statusline.sh hooks/*.sh tests/*.sh
# perf.sh thresholds, forwarded into the bash 3.2 container only when set.
PERF_ENV := PERF_RUNS PERF_BUDGET_MS PERF_MAX_FORKS PERF_MAX_SEG_RATIO PERF_MAX_RATIO

.PHONY: ci lint shellcheck actionlint manifests test test-bash32 perf perf-bash32

ci: lint test test-bash32 perf perf-bash32

lint: shellcheck actionlint manifests

# -S warning: vars assigned by eval or printf -v are declared or carry a
# per-line disable, so a new warning is a real one.
shellcheck:
	docker run --rm -v "$$PWD":/mnt:ro $(SHELLCHECK_IMAGE) -S warning $(SH_FILES)

actionlint:
	docker run --rm -v "$$PWD":/repo:ro -w /repo $(ACTIONLINT_IMAGE) -no-color

manifests:
	for f in .claude-plugin/*.json hooks/hooks.json; do jq empty "$$f" || exit 1; done
	p=$$(jq -r .version .claude-plugin/plugin.json); \
	m=$$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json); \
	echo "plugin.json=$$p marketplace.json=$$m"; [ "$$p" = "$$m" ]

# Functional tests. TEST_BASH selects the bash under test (macOS: /bin/bash).
test:
	bash tests/cache-ttl.sh
	bash tests/live-delta.sh
	bash tests/effort-alert.sh
	bash tests/prices.sh
	bash tests/plan-spend.sh

test-bash32:
	docker run --rm -v "$$PWD":/w:ro $(BASH32_IMAGE) \
	  bash -c 'apk add -q jq coreutils; bash /w/tests/cache-ttl.sh && bash /w/tests/live-delta.sh && bash /w/tests/effort-alert.sh && bash /w/tests/prices.sh && bash /w/tests/plan-spend.sh'

# On Linux, strace is required: without it perf.sh silently skips the fork gate.
perf:
	@if [ "$$(uname)" = Linux ] && ! command -v strace >/dev/null; then \
	  echo "make perf: strace not installed (the fork gate would be skipped)" >&2; exit 1; fi
	bash tests/perf.sh

perf-bash32:
	docker run --rm $(addprefix -e ,$(PERF_ENV)) -v "$$PWD":/w:ro $(BASH32_IMAGE) \
	  bash -c 'apk add -q jq coreutils; bash /w/tests/perf.sh'
