VERSION ?= 0.1.0

.PHONY: check package clean

check:
	./scripts/check.sh

package: check
	./scripts/package-release.sh "$(VERSION)"

clean:
	rm -rf dist
